from locust import HttpUser, task, between


class NotificationHealthUser(HttpUser):
    wait_time = between(2, 5)

    @task(1)
    def health_check(self):
        with self.client.get(
            "/actuator/health",
            catch_response=True
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Health check failed: {resp.status_code}")
