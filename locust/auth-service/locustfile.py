"""
Locust performance tests — auth-service
Simulates concurrent logins (dual-chain LDAP → local DB) and QR token issuance.
"""
from locust import HttpUser, task, between

CREDENTIALS = {"username": "staff_guard", "password": "password"}


class AuthUser(HttpUser):
    wait_time = between(1, 3)
    token = None

    def on_start(self):
        """Authenticate once per simulated user at spawn."""
        with self.client.post(
            "/api/v1/auth/login",
            json=CREDENTIALS,
            catch_response=True
        ) as response:
            if response.status_code == 200:
                self.token = response.json().get("token")
            else:
                response.failure(f"Login failed: {response.status_code}")

    @task(3)
    def generate_qr_token(self):
        """Most common authenticated operation — short-lived QR issuance."""
        if not self.token:
            return
        with self.client.get(
            "/api/v1/auth/qr/generate",
            headers={"Authorization": f"Bearer {self.token}"},
            catch_response=True
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Unexpected status: {resp.status_code}")

    @task(1)
    def fresh_login(self):
        """Measures full login latency (LDAP bind attempt + local DB fallback)."""
        with self.client.post(
            "/api/v1/auth/login",
            json=CREDENTIALS,
            name="/api/v1/auth/login (fresh)",
            catch_response=True
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Unexpected status: {resp.status_code}")
