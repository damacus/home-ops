# UniFi release announcer namespace migration

The announcer runs in `network`. It retains the existing image, chart and
credentials references. The former Longhorn volume is retained for rollback
until its contents and legacy role are understood.

The current Rust implementation reads Discord history to suppress duplicates;
its recent and uncertain send state is held in memory and lost on restart. Its
history windows are limited, and a cache copy does not preserve that in-memory
state. Before cutover, confirm the deployed image matches that implementation,
verify history access and investigate any uncertain send. Stop the old instance
and confirm it has terminated before starting the target; never run two writers
against Discord at once. Verify the target secret and existing announcements,
then confirm polling and the absence of duplicate sends. The old Helm-managed
claim has a Delete reclaim policy; protect its volume before uninstalling the
old release. Retain the old data until its contents and rollback role are understood.

The new claim size is 10 MiB, matching the former live claim; `10m` is an
invalid fractional-byte request.
