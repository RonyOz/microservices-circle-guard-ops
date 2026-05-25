"""
Locust performance tests — file-service
Simulates document uploads (health certificates, attachments).
"""
from locust import HttpUser, task, between
import io
import random
import string


def random_filename():
    suffix = ''.join(random.choices(string.ascii_lowercase, k=8))
    return f"certificate_{suffix}.pdf"


SAMPLE_PDF_BYTES = b"%PDF-1.4 fake-pdf-content-for-load-test"


class FileUser(HttpUser):
    wait_time = between(2, 5)
    token = None

    def on_start(self):
        resp = self.client.post(
            "/api/v1/auth/login",
            json={"username": "admin", "password": "admin"},
            catch_response=True
        )
        if resp.status_code == 200:
            self.token = resp.json().get("token")
        else:
            resp.failure(f"Login failed: {resp.status_code}")

    def _auth_headers(self):
        return {"Authorization": f"Bearer {self.token}"} if self.token else {}

    @task(1)
    def upload_document(self):
        """Upload a synthetic certificate PDF."""
        with self.client.post(
            "/api/v1/files/upload",
            headers=self._auth_headers(),
            files={"file": (random_filename(), io.BytesIO(SAMPLE_PDF_BYTES), "application/pdf")},
            name="/api/v1/files/upload",
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 201, 400, 401, 403):
                resp.failure(f"Unexpected: {resp.status_code}")
