from locust import HttpUser, task, between


class IdentityUser(HttpUser):
    wait_time = between(1, 2)

    @task(1)
    def health(self):
        self.client.get("/actuator/health")
