"""
Locust performance tests — dashboard-service
Simulates concurrent analytics queries across trends, health-board, and department views.
"""
from locust import HttpUser, task, between
import random
import uuid

DEPARTMENTS = ["engineering", "medicine", "law", "sciences", "business"]
# locationId is a UUID path variable — non-UUID values are rejected with 400
LOCATION_IDS = [str(uuid.uuid4()) for _ in range(20)]


# dashboard-service has no Spring Security by design (auth is enforced at the
# gateway), so the analytics endpoints are exercised without a token.
class DashboardUser(HttpUser):
    wait_time = between(1, 3)

    def _auth_headers(self):
        return {}

    @task(4)
    def health_board(self):
        """Most common — dashboard overview page."""
        with self.client.get(
            "/api/v1/analytics/health-board",
            headers=self._auth_headers(),
            catch_response=True
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Unexpected: {resp.status_code}")

    @task(3)
    def summary(self):
        with self.client.get(
            "/api/v1/analytics/summary",
            headers=self._auth_headers(),
            catch_response=True
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Unexpected: {resp.status_code}")

    @task(2)
    def trends_by_location(self):
        loc = random.choice(LOCATION_IDS)
        with self.client.get(
            f"/api/v1/analytics/trends/{loc}",
            headers=self._auth_headers(),
            name="/api/v1/analytics/trends/[locationId]",
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 404):
                resp.failure(f"Unexpected: {resp.status_code}")

    @task(2)
    def department_stats(self):
        dept = random.choice(DEPARTMENTS)
        with self.client.get(
            f"/api/v1/analytics/department/{dept}",
            headers=self._auth_headers(),
            name="/api/v1/analytics/department/[dept]",
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 404):
                resp.failure(f"Unexpected: {resp.status_code}")

    @task(1)
    def time_series(self):
        with self.client.get(
            "/api/v1/analytics/time-series",
            headers=self._auth_headers(),
            catch_response=True
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Unexpected: {resp.status_code}")
