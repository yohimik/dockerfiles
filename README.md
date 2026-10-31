# Dockerfiles

- [Laptop location client](laptop-location-client): cron and POSIX shell scripts for scheduled location, machine information, and file updates to a configured Git repository; client configuration snapshots are opt-in.
- [Laptop location server](laptop-location-server): daily GitHub checks that make the configured repository public after more than 30 days without a push, then remove their cron job.
- [Portable server function](laptop-location-server/function): the same inactivity check as a dependency-free Python function, with a callback for removing any hosting scheduler's trigger.
