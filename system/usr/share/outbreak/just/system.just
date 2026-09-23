# Make bootc verify the Outbreak signature on every upgrade (run once after install)
[group('System')]
enforce-signatures:
    sudo bootc switch --enforce-container-sigpolicy ghcr.io/sir-mudkip/outbreak:stable
    sudo bootc status
