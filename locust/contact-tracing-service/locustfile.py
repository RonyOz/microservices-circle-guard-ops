"""
Locust performance tests — contact-tracing-service
Simulates proximity event reporting and graph queries.
"""
from locust import HttpUser, task, between
import uuid
import random


class ContactTracingUser(HttpUser):
    wait_time = between(0.5, 2)

    @task(5)
    def report_proximity(self):
        """High-frequency: devices report proximity events continuously."""
        payload = {
            "reporterId": str(uuid.uuid4()),
            "observedId": str(uuid.uuid4()),
            "rssi": random.randint(-90, -40),
            "durationSeconds": random.randint(30, 600),
            "locationId": str(uuid.uuid4())
        }
        with self.client.post(
            "/api/contacts/proximity",
            json=payload,
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 201):
                resp.failure(f"proximity report failed: {resp.status_code}")

    @task(2)
    def get_contact_graph(self):
        """Medium-frequency: query contact graph for a user."""
        user_id = str(uuid.uuid4())
        with self.client.get(
            f"/api/contacts/{user_id}/graph?depth=2",
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 404):
                resp.failure(f"graph query failed: {resp.status_code}")

    @task(1)
    def get_exposure_risk(self):
        """Low-frequency: calculate exposure risk score."""
        user_id = str(uuid.uuid4())
        with self.client.get(
            f"/api/contacts/{user_id}/risk",
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 404):
                resp.failure(f"risk query failed: {resp.status_code}")
