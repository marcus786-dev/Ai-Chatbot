# CATS-lignende tidsregistrering — SPEC (bindende kontrakt)

Et program der minder om SAP CATS (Cross-Application Time Sheet): ugentlig tidsregistrering
på WBS-element + aktivitetstype, med statusflow I arbejde → Frigivet → Godkendt/Afvist,
godkendelse for ledere, rapporter og stamdata. **UI-tekst er på dansk.**

Teknik: Python 3 **kun standardbibliotek** (http.server, sqlite3, unittest) + vanilla JS (ingen
build, ingen frameworks, ingen CDN, ingen ES-moduler — almindelige `<script>`-tags).
Hver agent ejer KUN de filer, der er tildelt den. Rør aldrig andre filer.
Allerede skrevet (må ikke ændres): `backend/errors.py`, `backend/util.py`, `backend/schema.sql`.

## Filstruktur
```
backend/__init__.py  errors.py  util.py  schema.sql   (færdige)
backend/db.py                    connect/init_db/seed
backend/timesheet_service.py     ugeregistrering + statusflow
backend/masterdata_service.py    medarbejdere, WBS, aktivitetstyper, favoritter
backend/reports_service.py       rapporter + CSV
backend/server.py                HTTP-server + routing + roller
frontend/index.html  css/style.css  js/app.js
frontend/js/util.js  js/api.js
frontend/js/pages/timesheet.js  approvals.js  reports.js  admin.js
tests/test_timesheet.py  test_masterdata.py  test_reports.py  test_api.py
```

## Domæne
- Status pr. linje: `IN_PROCESS` ("I arbejde"), `RELEASED` ("Frigivet"), `APPROVED` ("Godkendt"),
  `REJECTED` ("Afvist"). Dansk label-map ligger i `window.Util.STATUS_LABEL`.
- Rolle: `employee`, `manager`, `admin`. Manager godkender sine direkte medarbejdere
  (`employee.manager_id == manager.id`); admin må alt.
- Timer: tal 0–24 pr. celle, trin 0,25; sum pr. dag ≤ 24. Uge = man–søn, `week_start` er mandagens ISO-dato.
- Linjer med status RELEASED/APPROVED er **låste** (kan ikke ændres via save).

## Backend-kontrakt
Alle service-funktioner tager `conn` (sqlite3.Connection, `row_factory=sqlite3.Row`) som første argument,
returnerer kun JSON-serialiserbare dicts/lister/str og rejser `ServiceError(message, status)` ved fejl.
Importér via `from .errors import ServiceError` og `from .util import ...` (pakke-relative imports).
Services committer selv (`conn.commit()`) efter skrivning og rollbacker ved fejl.

### db.py
- `connect(path) -> Connection` (`row_factory=sqlite3.Row`, `PRAGMA foreign_keys=ON`, `check_same_thread=False`; `":memory:"` tilladt).
- `init_db(conn)` kører `schema.sql` (find den relativt til filen).
- `seed(conn)` indsætter demodata hvis `employee` er tom (idempotent). Data:
  - Medarbejdere (id i rækkefølge): 1 `10000001` Anna Jensen employee mgr=4; 2 `10000002` Lars Nielsen employee mgr=4;
    3 `10000003` Maria Hansen employee mgr=4; 4 `10000004` Peter Sørensen manager mgr=NULL; 5 `10000005` Sys Admin admin mgr=NULL. weekly_target 37.0 for alle.
  - Aktivitetstyper: KONS Konsulentarbejde, UDV Udvikling, TEST Test, MOED Møder, ADM Administration, REJS Rejsetid, FRAV Fravær.
  - WBS (code, description, cost_center): `P-1001-01` ERP-implementering – analyse (1000); `P-1001-02` ERP-implementering – design (1000);
    `P-1001-03` ERP-implementering – test (1000); `P-2002-01` Support og drift (2000); `I-0001` Intern – møder og administration (9000);
    `I-0002` Intern – kompetenceudvikling (9000); `A-0001` Fravær – ferie (9100); `A-0002` Fravær – sygdom (9100). Alle active=1.
  - Timesheet-demodata relativt til `util.today()`: for medarbejder 1–3 de seneste 6 afsluttede uger med 37 t/uge fordelt man–fre
    (flere linjer, variér WBS/aktivitet pr. person), status APPROVED; undtagelse: seneste afsluttede uge for Lars (id 2) er RELEASED
    (så godkendelsesskærmen har noget), og for Maria (id 3) er hendes seneste afsluttede uge manglende helt (til "manglende"-rapporten).
    Indeværende uge for Anna: 1 linje med 16 t, IN_PROCESS. Favoritter for Anna: (P-1001-01,KONS), (I-0001,MOED).
- `main_db(path)` er ikke nødvendig. Kald `python3 -m backend.db <sti>` skal oprette+seede en fil-DB (`if __name__ == "__main__"`).

### Linje-dict (bruges af get_week, list_pending)
```json
{"id": 12, "wbs_code": "P-1001-01", "wbs_description": "…", "activity_code": "KONS", "activity_description": "…",
 "note": "", "status": "IN_PROCESS", "reject_reason": "", "hours": {"2026-10-19": 7.5, "2026-10-20": 0.0, "…7 datoer…": 0.0},
 "total": 7.5}
```
`hours` indeholder ALTID alle 7 datoer (0.0 hvis ingen). Linjer sorteres på wbs_code, activity_code.

### timesheet_service.py
- `get_week(conn, employee_id, week_start) -> {"employee_id", "week_start", "days": [7 datoer], "lines": [linje…],
  "day_totals": {dato: float}, "total": float, "target": float, "locked": bool}` — `locked` = alle linjer låste og der er ≥1 linje.
- `save_week(conn, employee_id, week_start, lines) -> get_week(...)`. `lines` = liste af
  `{"wbs_code", "activity_code", "note": "", "hours": {dato: float}}` (datoer skal ligge i ugen; manglende dato = 0).
  Regler: ikke-låste eksisterende linjer, der ikke er i payload, slettes; linjer i payload der matcher en **låst** linje
  (samme wbs+aktivitet) ignoreres; øvrige oprettes/opdateres (hours-rækker erstattes; 0 → ingen række). En REJECTED linje der gemmes
  bliver `IN_PROCESS` med tom reject_reason. Valider: wbs findes og er aktiv, aktivitet findes, ingen dubletter i payload (400),
  timer 0–24 og multiplum af 0,25 (400), dagssum inkl. låste linjer ≤ 24 (400), datoer i ugen (400), week_start mandag (400).
- `release_week(conn, employee_id, week_start) -> get_week`: alle IN_PROCESS/REJECTED linjer med total>0 → RELEASED. Tomme (total 0) ikke-låste linjer slettes.
  Hvis intet kan frigives → ServiceError 400 "Der er intet at frigive".
- `recall_week(conn, employee_id, week_start) -> get_week`: RELEASED → IN_PROCESS. APPROVED røres ikke. Intet at kalde tilbage → 400.
- `copy_previous_week(conn, employee_id, week_start) -> get_week`: opretter manglende linjer (kun wbs+aktivitet+note, uden timer, status IN_PROCESS)
  for kombinationer fra forrige uge, som ikke findes i denne uge, og som stadig er aktive. Ingen timer kopieres.
- `list_pending(conn, manager_id) -> [{"employee_id","pernr","name","week_start","total","lines":[linje…]}]`: grupperet pr. medarbejder+uge,
  kun linjer med status RELEASED (andre status-linjer i samme uge udelades). Manager: direkte medarbejdere. Admin: alle. Employee → 403.
  Sorteret på week_start, name.
- `approve(conn, manager_id, employee_id, week_start) -> {"approved": antal_linjer}`: RELEASED → APPROVED. Kun leder af medarbejderen eller admin (ellers 403). Intet at godkende → 400.
- `reject(conn, manager_id, employee_id, week_start, reason) -> {"rejected": antal_linjer}`: RELEASED → REJECTED, gem reason (påkrævet, ikke tom, ellers 400). Samme autorisation.
- Ukendt medarbejder → 404.

### masterdata_service.py
- `list_employees(conn) -> [{"id","pernr","name","role","manager_id","manager_name","weekly_target"}]` (sorteret på pernr)
- `get_employee(conn, employee_id) -> samme dict` (404 hvis ukendt)
- `list_wbs(conn, include_inactive=False) -> [{"code","description","cost_center","active": bool}]` (sorteret på code)
- `upsert_wbs(conn, code, description, cost_center, active=True) -> wbs-dict` — valider code (ikke-tom, ≤ 24 tegn, kun A-Z a-z 0-9 - _ .), description og cost_center ikke tomme (400).
- `list_activity_types(conn) -> [{"code","description"}]`; `upsert_activity_type(conn, code, description) -> dict` (code 1–8 tegn, A-Z/0-9, normaliseres til store bogstaver; 400 ved fejl).
- `list_favorites(conn, employee_id) -> [{"wbs_code","wbs_description","activity_code","activity_description"}]`
- `add_favorite(conn, employee_id, wbs_code, activity_code) -> list_favorites(...)` (idempotent; 404 hvis wbs/aktivitet ukendt)
- `remove_favorite(conn, employee_id, wbs_code, activity_code) -> list_favorites(...)`

### reports_service.py
Alle datoer ISO. `statuses` = None (alle) eller liste af statusser. `employee_id` = None betyder alle medarbejdere.
- `hours_by_wbs(conn, employee_id, date_from, date_to, statuses=None) -> [{"wbs_code","description","hours"}]` sorteret på hours desc, hours > 0.
- `hours_by_activity(conn, employee_id, date_from, date_to, statuses=None) -> [{"activity_code","description","hours"}]`
- `weeks_overview(conn, employee_id, year) -> [{"week_start","week_number","hours","target","status"}]` for alle ISO-uger i året (ISO-årets mandage;
  uge 1 indeholder 4. januar). `status`: None hvis ingen linjer; ellers værste: REJECTED > IN_PROCESS > RELEASED > APPROVED.
- `missing_timesheets(conn, manager_id, as_of) -> [{"employee_id","pernr","name","week_start","hours","target","missing"}]`: kontrollér ugen før den uge `as_of` ligger i.
  `hours` = sum af RELEASED+APPROVED timer. Med i listen hvis `hours < target`. Manager: direkte medarbejdere; admin: alle med rolle ≠ admin; employee → 403.
- `export_csv(conn, employee_id, date_from, date_to) -> str`: semikolon-separeret, UTF-8-tekst, header
  `Personalenr;Navn;Dato;WBS-element;Aktivitetstype;Timer;Status;Note`, timer med decimalkomma (`7,5`), sorteret på pernr, dato, wbs. `\r\n` linjeskift. Felter med `;`, `"` eller linjeskift citeres.
- Ugyldigt datointerval (from > to eller ugyldig dato) → 400.

### server.py
`python3 -m backend.server [--port 8000] [--host 127.0.0.1] [--db data/cats.db]` — opretter/seeder DB hvis den mangler, serverer `frontend/`
statisk på `/` (`/` → `index.html`; korrekte Content-Type; ingen path traversal) og JSON-API under `/api`. `ThreadingHTTPServer`; hver request åbner
sin egen connection via `db.connect` (eller en lås om én delt). Eksportér `make_server(db_path, host, port) -> ThreadingHTTPServer` (port 0 = tilfældig, bruges af tests).
**"Login"**: header `X-Employee-Id: <id>` (mangler/ukendt → 401). Alle svar JSON `UTF-8`; fejl: `{"error": "besked"}` med statuskoden fra `ServiceError`
(uventede fejl → 500 uden stacktrace til klienten; log til stderr). Ugyldig JSON-body → 400. Ukendt rute → 404; forkert metode → 405.

| Metode + sti | Beskrivelse | Rolle |
|---|---|---|
| `GET /api/employees` | list_employees | alle |
| `GET /api/me` | get_employee(me) | alle |
| `GET /api/wbs?all=1` | list_wbs (`all=1` → inkl. inaktive) | alle (all=1 kun admin) |
| `PUT /api/wbs/{code}` body `{description,cost_center,active}` | upsert_wbs | admin |
| `GET /api/activity-types` | list_activity_types | alle |
| `PUT /api/activity-types/{code}` body `{description}` | upsert_activity_type | admin |
| `GET /api/favorites` | list_favorites(me) | alle |
| `POST /api/favorites` body `{wbs_code,activity_code}` | add_favorite | alle |
| `DELETE /api/favorites?wbs_code=&activity_code=` | remove_favorite | alle |
| `GET /api/timesheet?week=YYYY-MM-DD` | get_week(me) (week udeladt → indeværende uges mandag) | alle |
| `PUT /api/timesheet?week=` body `{lines:[…]}` | save_week | alle |
| `POST /api/timesheet/release?week=` | release_week | alle |
| `POST /api/timesheet/recall?week=` | recall_week | alle |
| `POST /api/timesheet/copy-previous?week=` | copy_previous_week | alle |
| `GET /api/approvals` | list_pending(me) | manager, admin |
| `POST /api/approvals/approve` body `{employee_id,week}` | approve | manager, admin |
| `POST /api/approvals/reject` body `{employee_id,week,reason}` | reject | manager, admin |
| `GET /api/reports/by-wbs?from=&to=&employee_id=&status=A,B` | hours_by_wbs | se nedenfor |
| `GET /api/reports/by-activity?…` | hours_by_activity | se nedenfor |
| `GET /api/reports/weeks?year=&employee_id=` | weeks_overview | se nedenfor |
| `GET /api/reports/missing?as_of=` | missing_timesheets(me) | manager, admin |
| `GET /api/reports/export.csv?from=&to=&employee_id=` | export_csv, `Content-Type: text/csv; charset=utf-8`, `Content-Disposition: attachment; filename="tidsregistrering.csv"` | se nedenfor |

Rapport-adgang: `employee_id` udeladt → egen id for rolle employee; for manager/admin betyder udeladt/`all` = alle medarbejdere de må se
(manager: sig selv + direkte medarbejdere; admin: alle). Employee der beder om en andens id → 403; manager om en der ikke er hans → 403.
For manager med "alle" filtrerer serveren på tilladte id'er (kald service pr. id og læg sammen, eller tilføj intern hjælper — brug kun services' offentlige API).
`from`/`to` udeladt → seneste 30 dage. `year` udeladt → indeværende år. Manglende `week` ved PUT/POST → mandagen i indeværende uge.

## Frontend-kontrakt
Script-rækkefølge i `index.html`: `util.js`, `api.js`, `pages/timesheet.js`, `pages/approvals.js`, `pages/reports.js`, `pages/admin.js`, `app.js`.
Sider registrerer sig: `window.Pages.timesheet = { title: "Tidsregistrering", roles: ["employee","manager","admin"], render: async function (container, ctx) {…} }`
(sidenøgler: `timesheet`, `approvals` [roles manager,admin, titel "Godkendelse"], `reports` [alle roller, titel "Rapporter"], `admin` [admin, titel "Stamdata"]).
`ctx = { me: {id,pernr,name,role,manager_id,weekly_target}, employees: [...] }`. `render` tømmer selv `container` og bygger DOM (ingen innerHTML med brugerdata — brug `Util.h`). Fejl fra API vises med `Util.toast(err.message, "error")`.

### util.js → `window.Util`
- `h(tag, attrs, ...children)` — attrs: `class`, `dataset`, `style` (objekt), `on*` (event handlers som funktioner), `value`/`checked`/`disabled`/`readOnly`/`title` etc. som properties, resten som attributes (false/null/undefined udelades). Børn: string/Node/array/null.
- `clear(node)`, `toast(msg, type="info")` (type: info|success|error; element i `#toast-root`, forsvinder efter 4 s), `confirmDialog(msg) -> Promise<bool>`, `promptDialog(msg, {placeholder, required}) -> Promise<string|null>` (modal med `.modal-backdrop > .modal`).
- Datoer: `isoDate(Date)`, `parseIso(str) -> Date` (lokal tid, ingen UTC-fejl), `addDays(iso, n) -> iso`, `mondayOf(iso|Date) -> iso`, `isoWeekNumber(iso) -> int`, `fmtDate(iso) -> "dd/mm"`, `fmtDateFull(iso) -> "dd/mm/yyyy"`, `weekLabel(weekStart) -> "Uge 43, 2026 (19/10 – 25/10)"`, `todayIso()`, `WEEKDAYS = ["Man","Tir","Ons","Tor","Fre","Lør","Søn"]`.
- Tal: `fmtHours(n) -> "7,5"` (decimalkomma, op til 2 decimaler, 0 → "0"), `parseHours(str) -> number|NaN` (accepterer komma og punkt, tom → 0).
- `STATUS_LABEL = {IN_PROCESS:"I arbejde", RELEASED:"Frigivet", APPROVED:"Godkendt", REJECTED:"Afvist"}`, `statusBadge(status) -> <span class="status status-XXX">`.
- `downloadBlob(blob, filename)`.

### api.js → `window.API`
`API.employeeId` (læses/skrives i `localStorage["cats.employeeId"]`, default `1`), `API.setEmployee(id)`,
`API.get(path, params)`, `API.post(path, body, params)`, `API.put(path, body, params)`, `API.del(path, params)` — `path` fx `"/timesheet"`, prefikses med `/api`;
`params` objekt → querystring (udelad null/undefined). Sender `X-Employee-Id`. Returnerer parsed JSON; ved !ok kastes `Error(json.error || statusText)` med `.status`.
`API.getBlob(path, params) -> Promise<Blob>` (til CSV).

### app.js (skal/shell)
Hash-routing `#/timesheet` (default), `#/approvals`, `#/reports`, `#/admin`. Shell: `<header id="shellbar">` (logo-tekst "Tidsregistrering · CATS",
bruger-vælger `<select id="user-switch">` med alle medarbejdere "Navn (rolle)"; skift → `API.setEmployee`, genindlæs `me` og siden), `<nav id="nav">` med faner kun for sider hvor `roles` indeholder brugerens rolle
(aktiv fane har klassen `active`), `<main id="content">`, `<div id="toast-root">`. Hvis siden ikke er tilladt for rollen → redirect til `#/timesheet`.
Når `index.html` loades kalder `app.js` `init()` på DOMContentLoaded. Vis fejl hvis serveren ikke svarer.

### CSS-klasser (style.css SKAL style alle disse; siderne SKAL bruge dem)
Layout/generelt: `.page` (side-wrapper), `.page-title`, `.card`, `.card-title`, `.toolbar` (flex, gap), `.spacer` (flex:1), `.muted`, `.error-text`, `.empty` (tom-tilstand), `.hidden`.
Knapper: `.btn`, `.btn-primary`, `.btn-danger`, `.btn-ghost`, `.btn-icon`, `.btn:disabled`.
Formularer: `.field` (label + input stakket), `.form-row` (flex, wrap), `input`, `select`, `textarea` globalt stylet; `.tabs` + `.tab` (+ `.tab.active`).
Tabeller: `.table` (zebra, sticky header ikke påkrævet), `.num` (højrejusteret tal, tabular-nums), `.total-row`, `.weekend` (svag baggrund), `.over` (rød tekst/kant ved overskridelse), `.under` (gul/amber).
Tidsskema: `.ts-grid` (selve tabellen, kombineres med `.table`), `.hour-input` (smal, centreret, `width: 4.2em`), `.hour-input.invalid`, `.row-locked` (grå/let nedtonet række).
Status: `.status` (pille) + `.status-IN_PROCESS` (grå/blå), `.status-RELEASED` (blå), `.status-APPROVED` (grøn), `.status-REJECTED` (rød).
Rapporter: `.bar-wrap` (container i celle), `.bar` (grå spor), `.bar-fill` (farvet, bredde sættes inline i %).
Godkendelse: `.approval-card` (card variant), `.approval-head` (flex, navn+uge+knapper).
Dialog/toast: `.modal-backdrop`, `.modal`, `.modal-actions`, `#toast-root`, `.toast`, `.toast-info|success|error`.
Tema: SAP Fiori-agtigt — lys baggrund (#f5f6f7), shellbar mørkeblå (#354a5f) med hvid tekst, accent (#0a6ed1), kort med let skygge, 14px system-font, responsivt (nav og tabeller scroller vandret på smal skærm). Understøt `prefers-color-scheme: dark` med CSS-variabler.

### Sidernes funktioner
**timesheet.js** — ugenavigation (◀ Forrige, I dag, Næste ▶, `Util.weekLabel`); tabel `.table.ts-grid`: kolonner WBS-element (`<select>` "kode – beskrivelse", kun aktive), Aktivitetstype (`<select>`), Note (kort tekstfelt), Man…Søn (`.hour-input`, header med dato `dd/mm`, weekend-kolonner `.weekend`), Sum, Status (`Util.statusBadge`), handlinger (★ favorit-knap `.btn-icon`, slet-række `.btn-icon`).
Fodrække `.total-row`: dagssummer + samlet sum og "Mål: 37 t" med `.over`/`.under`. Låste linjer (RELEASED/APPROVED): inputs `disabled`, række `.row-locked`. REJECTED: vis begrundelse (title + synlig tekst under rækken eller banner). Knapper: "Tilføj række", "Tilføj fra favoritter" (`<select>` eller menu), "Kopiér forrige uge" (POST copy-previous), "Gem" (PUT), "Frigiv" (gemmer først, derefter POST release, bekræftelsesdialog), "Træk tilbage" (kun hvis der er RELEASED linjer).
Klient-validering: tal ≥0, ≤24, multiplum af 0,25; dagssum ≤24; ugyldige felter får `.invalid`. Tastatur: Enter/pil ned flytter til samme kolonne næste række; Tab normalt. Uændrede data → "Gem" deaktiveret; advar ved navigation væk fra ugen med ugemte ændringer (confirmDialog). Husk valgt uge i `sessionStorage`.
**approvals.js** — liste `.approval-card` pr. medarbejder+uge fra `GET /approvals`: `.approval-head` (navn, pernr, uge, total timer) + knapper "Godkend" og "Afvis" (promptDialog for begrundelse, påkrævet); under: kompakt tabel af linjer (WBS, aktivitet, Man–Søn, sum, note). Knap "Godkend alle" i toolbar (confirmDialog). Efter handling genindlæses listen. Tom tilstand `.empty` "Ingen tidsregistreringer afventer godkendelse".
**reports.js** — filterbjælke (Fra, Til, Medarbejder [kun manager/admin; "Alle" + hver], Status-multivalg valgfrit), faner (`.tabs`): "Timer pr. WBS", "Timer pr. aktivitet", "Ugeoversigt" (år-vælger; tabel med uge, timer, mål, status + `.bar` der viser timer/mål), "Manglende tidsregistrering" (kun manager/admin; vælg `as_of` dato), knap "Eksportér CSV" (`API.getBlob` + `Util.downloadBlob`). Tabeller med `.bar-wrap > .bar > .bar-fill` for timer (bredde relativt til maks), samlet sum nederst `.total-row`.
**admin.js** — kun admin. Faner: "WBS-elementer" (tabel med inline redigering af beskrivelse/kostsag/aktiv + "Nyt WBS-element"-formular; gem via PUT), "Aktivitetstyper" (tilsvarende), "Medarbejdere" (skrivebeskyttet tabel: pernr, navn, rolle, leder, normtid). Viser inaktive WBS (`?all=1`) med nedtonet række.

## Konventioner
- Python: PEP8, docstrings kort, ingen eksterne pakker, parametriserede SQL-kald (aldrig string-formatering af værdier).
- JS: `"use strict"` i en IIFE pr. fil; ingen globale variabler ud over `window.Util`, `window.API`, `window.Pages`; semikolon; kommentarer kun hvor logikken ikke er åbenlys.
- Sikkerhed: al brugerdata ind i DOM via `textContent`/`Util.h` — aldrig `innerHTML` med data.
- Verificér dit eget arbejde før du melder færdig: Python → `python3 -m py_compile <fil>`; JS → `node --check <fil>`.
- Tests bruger `unittest` og in-memory DB (`db.connect(":memory:")`, `init_db`, `seed`) eller `server.make_server(":memory:"…)`/temp-fil. Kør: `python3 -m unittest discover -s tests -v`.
