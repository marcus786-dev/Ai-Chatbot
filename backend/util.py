"""Delte dato-hjælpere. Alle datoer er ISO-strenge 'YYYY-MM-DD'. Uger starter mandag."""
from datetime import date, datetime, timedelta

from .errors import ServiceError


def parse_date(value):
    try:
        return datetime.strptime(value, "%Y-%m-%d").date()
    except (TypeError, ValueError):
        raise ServiceError("Ugyldig dato: %r (forventet YYYY-MM-DD)" % (value,), 400)


def monday_of(d):
    if isinstance(d, str):
        d = parse_date(d)
    return d - timedelta(days=d.weekday())


def check_week_start(value):
    """Validerer at værdien er en mandag. Returnerer date."""
    d = parse_date(value)
    if d.weekday() != 0:
        raise ServiceError("week_start skal være en mandag: %s" % value, 400)
    return d


def week_days(week_start):
    """De 7 ISO-datoer (man..søn) for en uge."""
    d = check_week_start(week_start) if isinstance(week_start, str) else week_start
    return [(d + timedelta(days=i)).isoformat() for i in range(7)]


def prev_week(week_start):
    return (check_week_start(week_start) - timedelta(days=7)).isoformat()


def today():
    return date.today()
