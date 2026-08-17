#!/usr/bin/env bash
# Publishes 15 DATA_CONNECTION change events to the FIFO topic, mirroring exactly
# what hank/db/change_events.go publishOne() puts on the wire:
#   - CloudEvents v1.0 envelope as the message body
#   - eventType / objectType / action / orgId / requestId as MessageAttributes
#   - MessageGroupId = requestId  (set by hank/aws/sns/service.go:48)
#
# 15 events across 6 request groups, so ordering-within-a-group is observable:
#   req-create-01  3 creates      req-update-01  3 updates     req-delete-01  3 deletes
#   req-create-02  2 creates      req-update-02  2 updates     req-delete-02  2 deletes
set -euo pipefail

export AWS_PROFILE=adidas-change-events AWS_REGION=us-east-2
TOPIC=arn:aws:sns:us-east-2:930272866731:aditya-change-events.fifo
SOURCE=urn:liveramp:cleanroom:local:forebitt
ORG=org-adidas-emea

# Five stable data-connection ids, so update/delete refer to the same objects the
# creates made. This is what lets you see one objectId travel across three groups.
OBJ=(
  "a1111111-1111-4111-8111-111111111111|Adidas EMEA S3 Feed"
  "a2222222-2222-4222-8222-222222222222|Adidas NAM Snowflake Feed"
  "a3333333-3333-4333-8333-333333333333|Adidas APAC GCS Feed"
  "a4444444-4444-4444-8444-444444444444|Adidas LATAM Azure Feed"
  "a5555555-5555-4555-8555-555555555555|Adidas Global CTV Feed"
)

n=0
publish() {
  local requestId="$1" action="$2" objectId="$3" objectName="$4"
  local verb ceid now
  case "$action" in
    CREATE) verb=created ;;
    UPDATE) verb=updated ;;
    DELETE) verb=deleted ;;
  esac
  ceid=$(uuidgen | tr 'A-Z' 'a-z')
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local etype="com.liveramp.cleanroom.data_connection.${verb}"

  # DELETE carries no objectName: audit.go only sets it when non-empty.
  local dataName=""
  if [ "$action" != "DELETE" ]; then
    dataName="\"objectName\":\"${objectName}\","
  fi

  local body
  body=$(cat <<JSON
{"specversion":"1.0","id":"${ceid}","source":"${SOURCE}","type":"${etype}","subject":"${ORG}/DATA_CONNECTION/${objectId}","time":"${now}","datacontenttype":"application/json","data":{"action":"${action}","objectId":"${objectId}",${dataName}"objectType":"DATA_CONNECTION","orgId":"${ORG}","requestId":"${requestId}"}}
JSON
)

  local attrs
  attrs=$(cat <<JSON
{"eventType":{"DataType":"String","StringValue":"${etype}"},
 "objectType":{"DataType":"String","StringValue":"DATA_CONNECTION"},
 "action":{"DataType":"String","StringValue":"${action}"},
 "orgId":{"DataType":"String","StringValue":"${ORG}"},
 "requestId":{"DataType":"String","StringValue":"${requestId}"}}
JSON
)

  local snsMsgId
  snsMsgId=$(aws sns publish \
    --topic-arn "$TOPIC" \
    --message-group-id "$requestId" \
    --message-attributes "$attrs" \
    --message "$body" \
    --query MessageId --output text)

  n=$((n+1))
  printf "  %2d. %-18s %-6s %-28s ce.id=%s  sns.MessageId=%s\n" \
    "$n" "$requestId" "$action" "$objectName" "$ceid" "$snsMsgId"
}

echo "===================================================================================="
echo "PUBLISHING 15 DATA_CONNECTION events to $TOPIC"
echo "===================================================================================="

echo
echo "-- req-create-01 (bulk create of 3) --"
for i in 0 1 2; do IFS='|' read -r id nm <<<"${OBJ[$i]}"; publish req-create-01 CREATE "$id" "$nm"; done
echo "-- req-create-02 (bulk create of 2) --"
for i in 3 4; do IFS='|' read -r id nm <<<"${OBJ[$i]}"; publish req-create-02 CREATE "$id" "$nm"; done

echo
echo "-- req-update-01 (bulk update of 3) --"
for i in 0 1 2; do IFS='|' read -r id nm <<<"${OBJ[$i]}"; publish req-update-01 UPDATE "$id" "$nm (renamed)"; done
echo "-- req-update-02 (bulk update of 2) --"
for i in 3 4; do IFS='|' read -r id nm <<<"${OBJ[$i]}"; publish req-update-02 UPDATE "$id" "$nm (renamed)"; done

echo
echo "-- req-delete-01 (bulk delete of 3) --"
for i in 0 1 2; do IFS='|' read -r id nm <<<"${OBJ[$i]}"; publish req-delete-01 DELETE "$id" "$nm"; done
echo "-- req-delete-02 (bulk delete of 2) --"
for i in 3 4; do IFS='|' read -r id nm <<<"${OBJ[$i]}"; publish req-delete-02 DELETE "$id" "$nm"; done

echo
echo "===================================================================================="
echo "published $n events"
echo "===================================================================================="
