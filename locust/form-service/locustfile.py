from locust import HttpUser, task, between
import random
import uuid
import datetime


class SurveyUser(HttpUser):
    wait_time = between(1, 3)

    @task(5)
    def submit_survey_no_symptoms(self):
        payload = {
            "anonymousId": str(uuid.uuid4()),
            "hasFever": False,
            "hasCough": False,
            "otherSymptoms": "none",
            "exposureDate": str(datetime.date.today())
        }
        with self.client.post(
            "/api/v1/surveys",
            json=payload,
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 201):
                resp.failure(f"Survey submit failed: {resp.status_code}")

    @task(2)
    def submit_survey_with_symptoms(self):
        payload = {
            "anonymousId": str(uuid.uuid4()),
            "hasFever": random.choice([True, False]),
            "hasCough": random.choice([True, False]),
            "otherSymptoms": random.choice(["", "headache", "fatigue", "loss of taste"]),
            "exposureDate": str(datetime.date.today() - datetime.timedelta(days=random.randint(0, 5)))
        }
        with self.client.post(
            "/api/v1/surveys",
            json=payload,
            catch_response=True
        ) as resp:
            if resp.status_code not in (200, 201):
                resp.failure(f"Survey submit failed: {resp.status_code}")
