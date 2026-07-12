# Preinstalled Auggie OCI image

This image is a direct-run alternative and a control for validating GCP,
credential, and pool connectivity independently of bootstrap-volume copying.
It contains Rocky Linux 8, Git, CA roots, pinned Node, and Auggie runtime files.

Both build arguments are mandatory digest-pinned references:

- `ROCKY_BASE_IMAGE`: approved Rocky Linux 8 minimal image.
- `BOOTSTRAP_IMAGE`: customer-built image from `deploy/bootstrap`.

Build and publish it in the customer supply chain, then deploy by digest with
Helm `bootstrap.mode=preinstalled`. No credential, pool ID, registry token, or
tenant value belongs in the image, build arguments, or image labels.

The image runs as UID/GID `1000`, places `auggie` on `PATH`, verifies the copied
runtime during the build, and is compatible with the chart's read-only root,
writable home/tmp/workspace mounts, and dropped-capability security context.

Use `preinstalled` as a deliberate packaging choice or diagnostic control. A
successful control does not qualify `bootstrapImage`; validate both modes when
bootstrap-volume initialization is the intended production path.