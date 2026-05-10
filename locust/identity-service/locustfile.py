from locust import HttpUser, task, between
import random
import uuid
import string


def random_real_identity():
    return ''.join(random.choices(string.ascii_lowercase, k=8)) + "@university.edu"


class IdentityUser(HttpUser):
    wait_time = between(1, 3)

    @task(2)
    def map_identity(self):
        payload = {"realIdentity": random_real_identity()}
        with self.client.post(
            "/api/v1/identities/map",
            json=payload,
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 201):
                resp.failure(f"Map identity failed: {resp.status_code}")

    @task(1)
    def register_visitor(self):
        payload = {
            "name": "Test Visitor",
            "email": random_real_identity(),
            "reason_for_visit": random.choice(["meeting", "delivery", "maintenance"])
        }
        with self.client.post(
            "/api/v1/identities/visitor",
            json=payload,
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 201):
                resp.failure(f"Visitor registration failed: {resp.status_code}")

    @task(3)
    def lookup_identity(self):
        uid = str(uuid.uuid4())
        with self.client.get(
            f"/api/v1/identities/lookup/{uid}",
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 401, 403, 404):
                resp.failure(f"Lookup failed: {resp.status_code}")
