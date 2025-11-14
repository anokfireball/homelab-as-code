#!/bin/bash
set +e

START=$(date +%s%3N)
ansible-pull -U https://github.com/anokfireball/homelab-as-code.git \
    --inventory "$(hostname --short)," \
    ansible/gateway/gateway.yaml
RC=$?
END=$(date +%s%3N)
DURATION_MS=$((END - START))

if [ "$RC" -eq 0 ]; then
    SUCCESS=true
else
    SUCCESS=false
fi

curl -s -S -X POST \
    -H "Authorization: Bearer j8EwZNd6w4TGP3twjFHyErtToDQnhEWTXvT3WjekQvDzqcjsdHML7fbovPEeEEFr" \
    --globoff \
    "https://gatus.kthxbye.cyou/api/v1/endpoints/neti_neti-[ansible]/external?success=${SUCCESS}&duration=${DURATION_MS}ms" \
    --resolve gatus.kthxbye.cyou:443:$(dig @1.1.1.1 +short gatus.kthxbye.cyou)

exit $RC
