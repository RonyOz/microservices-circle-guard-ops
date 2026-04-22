"""
Locust performance tests — auth-service
Simulates concurrent login + token refresh flows.
"""
from locust import HttpUser, task, between
import json
import random
import string


def random_user():
    suffix = ''.join(random.choices(string.ascii_lowercase, k=6))
    return f"testuser_{suffix}@circleguard.edu"


class AuthUser(HttpUser):
    wait_time = between(1, 3)
    token = None

    def on_start(self):
        """Authenticate once per simulated user at spawn."""
        response = self.client.post(
            "/api/auth/login",
            json={"email": random_user(), "password": "TestPass123!"},
            catch_response=True
        )
        if response.status_code == 200:
            self.token = response.json().get("token")
        else:
            response.failure(f"Login failed: {response.status_code}")

    @task(3)
    def validate_token(self):
        """Most common operation — validate an existing token."""
        if not self.token:
            return
        with self.client.get(
            "/api/auth/validate",
            headers={"Authorization": f"Bearer {self.token}"},
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 401):
                resp.failure(f"Unexpected status: {resp.status_code}")

    @task(1)
    def refresh_token(self):
        """Less frequent — refresh tokens near expiry."""
        if not self.token:
            return
        with self.client.post(
            "/api/auth/refresh",
            headers={"Authorization": f"Bearer {self.token}"},
            catch_response=True
        ) as resp:
            if resp.status_code == 200:
                self.token = resp.json().get("token")
            elif resp.status_code not in (401, 403):
                resp.failure(f"Unexpected status: {resp.status_code}")
