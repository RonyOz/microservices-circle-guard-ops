from locust import HttpUser, task, between


class MobileUser(HttpUser):
    wait_time = between(1, 3)

    @task(3)
    def load_homepage(self):
        with self.client.get(
            "/",
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 301, 302, 304):
                resp.failure(f"Homepage load failed: {resp.status_code}")

    @task(1)
    def health_check(self):
        with self.client.get(
            "/actuator/health",
            catch_response=True
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Health check failed: {resp.status_code}")
