from locust import HttpUser, task, between
import random
import string


def random_token():
    return ''.join(random.choices(string.ascii_letters + string.digits, k=40))


class GateUser(HttpUser):
    wait_time = between(0.5, 2)

    @task(3)
    def validate_token(self):
        payload = {"token": random_token()}
        with self.client.post(
            "/api/v1/gate/validate",
            json=payload,
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 401, 403):
                resp.failure(f"Unexpected status: {resp.status_code}")
