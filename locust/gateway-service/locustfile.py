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
            # 429 is expected under load: every virtual user shares one client IP
            # via port-forward, so they hit the same rate-limit bucket. A 429 means
            # the limiter is working, not that the service failed.
            if resp.status_code not in (200, 401, 403, 429):
                resp.failure(f"Unexpected status: {resp.status_code}")
