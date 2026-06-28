# Quick Start

This is a common path from a fresh installation to your first container.

## 1. Log In

Open `http://YOUR_SERVER_IP:8999` and sign in with the administrator account.

After entering the panel, check:

- Whether the dashboard shows host resources.
- Whether Image Management can list templates.
- Whether NAT and IPv6 status in Routing match your host network.

## 2. Download an Image

Open Image Management, choose a template, and download it. On small hosts, lightweight images such as Alpine or Debian are a good first choice.

Image downloads run asynchronously. You can watch progress in the task queue.

## 3. Create a Container

Open Container Management and click Create:

- Select virtualization type and template.
- Set CPU, memory, and disk.
- Set traffic limits and expiration time.
- If external access is required, add NAT port mappings or assign IPv6 from the container details page after creation.

## 4. Open a Terminal

After the container is created, open WebSSH from the details page. KVM virtual machines can use WebVNC for console access.

## 5. Share with a Sub-user

If another user needs to manage a container, create an access link in Sub-user Management. The sub-user only sees authorized containers and is limited by the operation scope configured by the administrator.
