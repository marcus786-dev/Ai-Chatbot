class ServiceError(Exception):
    """Forretningsfejl. `status` er den HTTP-statuskode serveren svarer med."""

    def __init__(self, message, status=400):
        super().__init__(message)
        self.message = message
        self.status = status
