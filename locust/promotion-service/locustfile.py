from locust import HttpUser, task, between
import random
import uuid
import string


def random_anon():
    return str(uuid.uuid4())


class PromotionUser(HttpUser):
    wait_time = between(1, 3)

    @task(3)
    def report_encounter(self):
        payload = {
            "sourceId": random_anon(),
            "targetId": random_anon(),
            "locationId": random_anon()
        }
        with self.client.post(
            "/api/v1/encounters/report",
            json=payload,
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 201, 204):
                resp.failure(f"Encounter report failed: {resp.status_code}")

    @task(2)
    def get_mesh_stats(self):
        with self.client.get(
            f"/api/v1/mesh/stats/{random_anon()}",
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 404):
                resp.failure(f"Mesh stats failed: {resp.status_code}")

    @task(1)
    def get_circles_for_user(self):
        with self.client.get(
            f"/api/v1/circles/user/{random_anon()}",
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 404):
                resp.failure(f"Circle query failed: {resp.status_code}")

    @task(1)
    def health_check(self):
        with self.client.get(
            "/actuator/health",
            catch_response=True
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Health check failed: {resp.status_code}")
