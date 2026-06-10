"""
Locust performance tests — file-service
Simulates document uploads (health certificates, attachments).
"""
from locust import HttpUser, task, between
import io
import os
import random
import string

import requests


def random_filename():
    suffix = ''.join(random.choices(string.ascii_lowercase, k=8))
    return f"certificate_{suffix}.pdf"


SAMPLE_PDF_BYTES = b"%PDF-1.4 fake-pdf-content-for-load-test"


class FileUser(HttpUser):
    wait_time = between(2, 5)
    token = None

    def on_start(self):
        # file-service does not serve /auth/login — a token is only obtainable
        # when auth-service is reachable (AUTH_URL env). Without it, uploads
        # are exercised unauthenticated (service enforces auth at the gateway).
        auth_url = os.environ.get("AUTH_URL", "")
        if not auth_url:
            return
        try:
            resp = requests.post(
                f"{auth_url}/api/v1/auth/login",
                json={"username": "staff_guard", "password": "password"},
                timeout=5,
            )
            if resp.status_code == 200:
                self.token = resp.json().get("token")
        except requests.RequestException:
            pass

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
