import boto3


def session_for_account(account):
    """Build a boto3 Session for a stored aws_accounts row (decrypting keys).

    Accepts sqlite3.Row or dict.
    """
    from crypto import decrypt_secret

    if not isinstance(account, dict):
        account = dict(account)
    access_key = decrypt_secret(account["access_key_enc"])
    secret_key = decrypt_secret(account["secret_key_enc"])
    region = account["region"] or "us-east-1"
    return boto3.Session(
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name=region,
    )


def account_identity(account):
    """Get sts.get_caller_identity for an account; return dict or error string."""
    try:
        if not isinstance(account, dict):
            account = dict(account)
        session = session_for_account(account)
        sts = session.client("sts")
        identity = sts.get_caller_identity()
        return {
            "ok": True,
            "account_id": identity.get("Account", ""),
            "arn": identity.get("Arn", ""),
            "region": account.get("region") or "us-east-1",
            "name": account.get("name"),
        }
    except Exception as e:
        return {"ok": False, "error": str(e)}


def describe_images(account, project_tag="GoldenImage", state="available"):
    """List images tagged with project; returns (list, error)."""
    try:
        ec2 = session_for_account(account).client("ec2")
        response = ec2.describe_images(
            Filters=[
                {"Name": "tag:Project", "Values": [project_tag]},
                {"Name": "state", "Values": [state]},
            ],
            Owners=["self"],
        )
        images = []
        for img in response.get("Images", []):
            tags = {t["Key"]: t["Value"] for t in img.get("Tags", [])}
            name = img.get("Name", "")
            layer = "customized" if ("/custom" in name or "custom" in tags.get("Name", "").lower()) else "base"
            images.append({
                "ami_id": img["ImageId"],
                "name": name,
                "os": tags.get("OS", "unknown"),
                "customer": tags.get("Customer", "unknown"),
                "layer": layer,
                "created": img.get("CreationDate"),
            })
        return images, None
    except Exception as e:
        return [], str(e)


def describe_single_image(account, ami_id):
    """Return {ami_id, name, os, customer, layer, created} for a specific AMI, or (None, error)."""
    try:
        ec2 = session_for_account(account).client("ec2")
        resp = ec2.describe_images(ImageIds=[ami_id])
        images = resp.get("Images", [])
        if not images:
            return None, f"AMI {ami_id} not found"
        img = images[0]
        tags = {t["Key"]: t["Value"] for t in img.get("Tags", [])}
        name = img.get("Name", "")
        layer = "customized" if ("/custom" in name or "custom" in tags.get("Name", "").lower()) else "base"
        return {
            "ami_id": img["ImageId"],
            "name": name,
            "os": tags.get("OS", ""),
            "customer": tags.get("Customer", ""),
            "layer": layer,
            "created": img.get("CreationDate"),
        }, None
    except Exception as e:
        return None, str(e)


def resolve_image_on_aws(account, name):
    """Look up an AMI ID by image name on AWS (any owner/visibility)."""
    try:
        ec2 = session_for_account(account).client("ec2")
        response = ec2.describe_images(
            Filters=[{"Name": "name", "Values": [name]}],
            MaxResults=10,
        )
        images = response.get("Images", [])
        if not images:
            return ""
        images.sort(key=lambda i: i.get("CreationDate", ""), reverse=True)
        return images[0]["ImageId"]
    except Exception:
        return ""