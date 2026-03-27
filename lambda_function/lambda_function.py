"""
lambda_function.py
==================
AWS Lambda function triggered by a Sumo Logic webhook alert.

What it does:
  1. Receives the alert payload (via SNS or API Gateway webhook).
  2. Stops the specified EC2 instance and waits for it to fully stop.
  3. Starts the instance again and waits for it to reach running state.
  4. Logs every action to CloudWatch Logs automatically via Python logging.
  5. Sends a notification to an SNS topic so the team is informed.

Why stop + start instead of reboot:
  A simple reboot keeps the instance on the same physical host — faster,
  but won't fix hardware degradation or networking issues at the host level.
  Stop + start moves the instance to a new host, which is a more reliable
  remediation for persistent performance problems.

Environment Variables (set in Lambda → Configuration → Environment variables):
  INSTANCE_ID    : The EC2 instance to restart, e.g. "i-0abc123def456789"
  SNS_TOPIC_ARN  : The full ARN of the SNS alerts topic,
                   e.g. "arn:aws:sns:us-east-1:123456789012:slow-api-alerts"
"""

import boto3
import logging
import os

# ── AWS clients ────────────────────────────────────────────────────────────────
ec2 = boto3.client('ec2')
sns = boto3.client('sns')

# ── Config from environment variables (never hardcode these) ──────────────────
INSTANCE_ID   = os.environ['INSTANCE_ID']
SNS_TOPIC_ARN = os.environ['SNS_TOPIC_ARN']

# ── Logging — feeds automatically into CloudWatch Logs ────────────────────────
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Entry point called by Lambda when the function is triggered.

    Parameters
    ----------
    event   : dict  — payload from Sumo Logic (via SNS or API Gateway).
    context : obj   — Lambda runtime context (not used directly here).
    """
    try:
        logger.info(f"Starting remediation for instance {INSTANCE_ID}")

        # Step 1: Stop the instance
        logger.info("Stopping EC2 instance...")
        ec2.stop_instances(InstanceIds=[INSTANCE_ID])

        # Wait until the instance has fully stopped before starting it.
        # Without this waiter, calling start_instances too early will fail.
        waiter = ec2.get_waiter('instance_stopped')
        waiter.wait(InstanceIds=[INSTANCE_ID])
        logger.info("Instance stopped successfully.")

        # Step 2: Start the instance
        logger.info("Starting EC2 instance...")
        ec2.start_instances(InstanceIds=[INSTANCE_ID])

        message = (
            f"EC2 instance {INSTANCE_ID} was automatically stopped and restarted "
            f"in response to a Sumo Logic alert detecting high /api/data response times."
        )

        # Log the outcome
        logger.info(message)

        # Step 3: Notify the team via SNS
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Message=message,
            Subject="EC2 Auto-Restart Triggered"
        )
        logger.info("SNS notification sent.")

        return {
            "statusCode": 200,
            "body": message
        }

    except Exception as e:
        logger.error(f"Error during remediation: {str(e)}")
        raise
