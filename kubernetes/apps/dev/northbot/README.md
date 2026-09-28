# NorthBot in home-ops

Flux deploys one NorthBot replica in `dev`. Its SQLite case file lives on the
`northbot` OpenEBS hostpath claim. Removing the Flux app leaves the claim in
place, so a rename or retirement does not silently delete reports and evidence.

To retire or migrate the bot, stop the Deployment first. Preserve the SQLite
database and its WAL/SHM files together while the process is stopped, verify a
restored copy, then update the new Deployment to use the retained claim or a
restored claim. Delete the old claim only after the retention and backup decision
has been recorded. The claim is node-local and is not a backup.

The `northbot-refresh` CronJob restarts the Deployment at 04:00 London time so
the mutable Forgejo `main` tag is pulled each day. The Deployment-level Reloader
annotation restarts it when the 1Password-sourced Kubernetes Secret changes.
