# Show the booted, staged and rollback images
[group('Updates')]
update-status:
    sudo bootc status

# Check for and stage an update now (applied at the next reboot)
[group('Updates')]
update-now:
    sudo systemctl start outbreak-stage-update.service
    sudo bootc status
