# Image Management

Image Management maintains templates used to create containers or virtual machines.

## Supported Template Types

The project includes common Linux distribution templates such as Debian, Ubuntu, Alpine, CentOS, Fedora, Arch Linux, and Rocky Linux. KVM templates use the corresponding distribution cloud image resources.

## Management Actions

```http
GET /api/v1/templates
GET /api/v1/images
POST /api/v1/images/download
POST /api/v1/images/cancel
DELETE /api/v1/images/delete
PUT /api/v1/images/toggle
```

- `templates` returns available template definitions.
- `images` returns local image status.
- `download` downloads a specific template.
- `cancel` cancels a download task.
- `delete` removes the local image cache.
- `toggle` controls whether a template can be used during creation.

## Windows Images

This project does not distribute Windows system images and does not provide features to bypass or avoid Windows activation. Windows download links should point to official Microsoft resources, and users must obtain valid licenses themselves.
