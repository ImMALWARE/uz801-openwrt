#!/bin/sh

. /lib/functions.sh
. /usr/share/libubox/jshn.sh

DB_FILE="/etc/sms_archive.db"

sqlite3 "$DB_FILE" <<SQL_INIT
CREATE TABLE IF NOT EXISTS sms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sender TEXT,
    message TEXT,
    receive_date TEXT,
    email_sent INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    error_date DATETIME DEFAULT CURRENT_TIMESTAMP,
    error_type TEXT,
    raw_data TEXT,
    description TEXT
);
SQL_INIT

config_load sms_sync
config_get enable_email main enable_email "0"
config_get smtp_server main smtp_server ""
config_get smtp_port main smtp_port "465"
config_get smtp_user main smtp_user ""
config_get smtp_pass main smtp_pass ""
config_get email_to main email_to ""
config_get email_from main email_from ""

sql_text() {
    printf "CAST(X'%s' AS TEXT)" "$(printf '%s' "$1" | hexdump -v -e '1/1 "%02x"')"
}

sql_file_text() {
    printf "CAST(X'%s' AS TEXT)" "$(hexdump -v -e '1/1 "%02x"' "$1")"
}

decode_ucs2() {
    printf '%s\n' "$1" | LC_ALL=C awk '
function hex2dec(h,   i, result, digit) {
    result = 0
    for (i = 1; i <= length(h); i++) {
        digit = index("0123456789ABCDEF", toupper(substr(h, i, 1))) - 1
        result = result * 16 + digit
    }
    return result
}
{
    value = $0
    if (value !~ /^[0-9A-Fa-f]+$/ || length(value) % 4 != 0) {
        printf "%s", value
        next
    }
    for (i = 1; i <= length(value); i += 4) {
        codepoint = hex2dec(substr(value, i, 4))
        if (codepoint < 128) {
            printf "%c", codepoint
        } else if (codepoint < 2048) {
            printf "%c%c", 192 + int(codepoint / 64), 128 + codepoint % 64
        } else {
            printf "%c%c%c", 224 + int(codepoint / 4096), 128 + int((codepoint % 4096) / 64), 128 + codepoint % 64
        }
    }
}'
}

save_ucs2_sms() {
    sms_indexes="$1"
    sms_sender="$2"
    sms_date="$3"
    sms_payload="$4"
    sms_file="$(mktemp /tmp/sms_message.XXXXXX)" || return 1

    decode_ucs2 "$sms_payload" > "$sms_file"
    if sqlite3 "$DB_FILE" "INSERT INTO sms (sender, message, receive_date) VALUES ($(sql_text "$sms_sender"), $(sql_file_text "$sms_file"), $(sql_text "$sms_date"));"; then
        for sms_index in $sms_indexes; do
            ubus call modem_at exec "{\"cmd\": \"AT+CMGD=$sms_index\"}" > /dev/null 2>&1
        done
    else
        sqlite3 "$DB_FILE" "INSERT INTO errors (error_type, raw_data, description) VALUES ('DB_ERROR', $(sql_text "$sms_indexes"), 'Failed to save SMS indexes $sms_indexes to DB');"
    fi
    rm -f "$sms_file"
}

parse_pdu_records() {
    LC_ALL=C awk '
function hex2dec(value, position, result, digit) {
    result = 0
    for (position = 1; position <= length(value); position++) {
        digit = index("0123456789ABCDEF", toupper(substr(value, position, 1))) - 1
        result = result * 16 + digit
    }
    return result
}
function byte_at(value, position) {
    return hex2dec(substr(value, position, 2))
}
function semi_octet(value) {
    return substr(value, 2, 1) substr(value, 1, 1)
}
function sender_number(value, digits, toa, position, sender) {
    sender = ""
    for (position = 1; position <= length(value); position += 2)
        sender = sender semi_octet(substr(value, position, 2))
    sender = substr(sender, 1, digits)
    return (toupper(toa) == "91" ? "+" : "") sender
}
function sender_alphanumeric(value, characters, position, byte_count, bytes, bit_position, byte_index, shift, septet) {
    byte_count = int((characters * 7 + 7) / 8)
    for (position = 0; position < byte_count; position++)
        bytes[position] = byte_at(value, position * 2 + 1)

    sender = ""
    for (position = 0; position < characters; position++) {
        bit_position = position * 7
        byte_index = int(bit_position / 8)
        shift = bit_position % 8
        septet = int(bytes[byte_index] / (2 ^ shift)) % 128
        if (shift > 1)
            septet += (bytes[byte_index + 1] % (2 ^ (shift - 1))) * (2 ^ (8 - shift))
        sender = sender sprintf("%c", septet)
    }
    return sender
}
function received_date(value) {
    return semi_octet(substr(value, 1, 2)) "/" semi_octet(substr(value, 3, 2)) "/" semi_octet(substr(value, 5, 2)) "," semi_octet(substr(value, 7, 2)) ":" semi_octet(substr(value, 9, 2)) ":" semi_octet(substr(value, 11, 2))
}
function emit_error(index_value, description, raw) {
    printf "E\t%s\t%s\t%s\n", index_value, description, raw
}
function parse_pdu(index_value, pdu, position, smsc_length, first_octet, address_length, address_type, address_bytes, address, pid, dcs, timestamp, user_length, user_data, udhl, header, header_position, iei, ie_length, reference, total, sequence, payload) {
    if (pdu !~ /^[0-9A-Fa-f]+$/ || length(pdu) < 30) {
        emit_error(index_value, "Invalid PDU", pdu)
        return
    }

    position = 1
    smsc_length = byte_at(pdu, position)
    position += 2 + smsc_length * 2
    first_octet = byte_at(pdu, position)
    if (first_octet % 4 != 0) {
        emit_error(index_value, "Unsupported TPDU type", pdu)
        return
    }
    position += 2
    address_length = byte_at(pdu, position)
    position += 2
    address_type = substr(pdu, position, 2)
    position += 2
    address_bytes = (toupper(address_type) == "D0" ? int((address_length * 7 + 7) / 8) : int((address_length + 1) / 2))
    address = (toupper(address_type) == "D0" ? sender_alphanumeric(substr(pdu, position, address_bytes * 2), address_length) : sender_number(substr(pdu, position, address_bytes * 2), address_length, address_type))
    position += address_bytes * 2
    pid = byte_at(pdu, position)
    position += 2
    dcs = byte_at(pdu, position)
    position += 2
    timestamp = received_date(substr(pdu, position, 14))
    position += 14
    user_length = byte_at(pdu, position)
    position += 2
    user_data = substr(pdu, position, user_length * 2)

    if (dcs != 8) {
        emit_error(index_value, "Unsupported SMS encoding", pdu)
        return
    }

    reference = "-"
    total = 1
    sequence = 1
    payload = user_data
    if (int(first_octet / 64) % 2 == 1) {
        udhl = byte_at(user_data, 1)
        header = substr(user_data, 3, udhl * 2)
        header_position = 1
        while (header_position <= length(header)) {
            iei = byte_at(header, header_position)
            ie_length = byte_at(header, header_position + 2)
            if (iei == 0 && ie_length == 3) {
                reference = substr(header, header_position + 4, 2)
                total = byte_at(header, header_position + 6)
                sequence = byte_at(header, header_position + 8)
            }
            header_position += 4 + ie_length * 2
        }
        payload = substr(user_data, 3 + udhl * 2)
    }

    if (length(payload) % 4 != 0 || total < 1 || sequence < 1 || sequence > total) {
        emit_error(index_value, "Invalid UCS-2 payload or concatenation header", pdu)
        return
    }
    printf "P\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", index_value, address, timestamp, reference, total, sequence, payload
}
/^\+CMGL:/ {
    index_value = $0
    sub(/^\+CMGL:[ \t]*/, "", index_value)
    sub(/,.*/, "", index_value)
    waiting_pdu = (index_value ~ /^[0-9]+$/)
    next
}
waiting_pdu && /^[0-9A-Fa-f]+$/ {
    parse_pdu(index_value, $0)
    waiting_pdu = 0
}
'
}

process_concatenated_group() {
    group_file="$1"
    if ! awk -F "\t" '
        NR == 1 { total = $5 }
        $1 < 1 || $1 > total || seen[$1]++ { exit 1 }
        END {
            if (NR != total) exit 1
            for (sequence = 1; sequence <= total; sequence++)
                if (!(sequence in seen)) exit 1
        }
    ' "$group_file"; then
        return
    fi

    sms_indexes=""
    sms_sender=""
    sms_date=""
    sms_payload=""
    sorted_group_file="$group_file.sorted"
    sort -n "$group_file" > "$sorted_group_file"
    while IFS="$(printf '\t')" read -r sequence sms_index sender received_date total payload; do
        [ "$sequence" = "1" ] && {
            sms_sender="$sender"
            sms_date="$received_date"
        }
        sms_indexes="$sms_indexes $sms_index"
        sms_payload="$sms_payload$payload"
    done < "$sorted_group_file"
    save_ucs2_sms "$sms_indexes" "$sms_sender" "$sms_date" "$sms_payload"
}

ubus call modem_at exec '{"cmd": "AT+CMGF=0"}' > /dev/null 2>&1
ubus call modem_at exec '{"cmd": "AT+CPMS=\"SM\",\"SM\",\"SM\""}' > /dev/null 2>&1

RAW_JSON=$(ubus call modem_at exec '{"cmd": "AT+CMGL=4"}')
json_load "$RAW_JSON"
json_get_var RAW_TEXT response

work_dir="$(mktemp -d /tmp/sms_pdu.XXXXXX)" || exit 1
records_file="$work_dir/records"
printf '%s\n' "$RAW_TEXT" | tr -d '\r' | parse_pdu_records > "$records_file"

while IFS="$(printf '\t')" read -r record_type sms_index sms_sender sms_date reference total sequence payload; do
    case "$record_type" in
        P)
            if [ "$total" = "1" ]; then
                save_ucs2_sms "$sms_index" "$sms_sender" "$sms_date" "$payload"
            else
                group_key="$(printf '%s' "$sms_sender|$reference|$total" | hexdump -v -e '1/1 "%02x"')"
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sequence" "$sms_index" "$sms_sender" "$sms_date" "$total" "$payload" >> "$work_dir/group_$group_key"
            fi
            ;;
        E)
            sqlite3 "$DB_FILE" "INSERT INTO errors (error_type, raw_data, description) VALUES ('PARSE_FAIL', $(sql_text "$sms_date"), $(sql_text "$sms_sender"));"
            ;;
    esac
done < "$records_file"

for group_file in "$work_dir"/group_*; do
    [ -f "$group_file" ] && process_concatenated_group "$group_file"
done
rm -rf "$work_dir"

if [ "$enable_email" = "1" ] && [ -n "$smtp_server" ] && [ -n "$email_to" ]; then
    sqlite3 "$DB_FILE" "SELECT id FROM sms WHERE email_sent = 0;" | while IFS= read -r id; do
        TMPBODY=$(mktemp /tmp/sms_body.XXXXXX)
        sender=$(sqlite3 "$DB_FILE" "SELECT sender FROM sms WHERE id = $id;")
        sqlite3 "$DB_FILE" "SELECT message FROM sms WHERE id = $id;" > "$TMPBODY"
        if [ "$smtp_port" = "587" ]; then
            SSL_FLAG="-starttls"
        else
            SSL_FLAG="-ssl"
        fi
        SMTP_USER_PASS="$smtp_pass" mailsend \
            -smtp "$smtp_server" -port "$smtp_port" \
            -t "$email_to" -f "$email_from" \
            -sub "SMS from $sender" \
            -mime-type "text/plain" -cs UTF-8 -enc-type "base64" -msg-body "$TMPBODY" \
            $SSL_FLAG -ehlo -auth -user "$smtp_user"
        RET=$?
        rm -f "$TMPBODY"
        if [ $RET -eq 0 ]; then
            sqlite3 "$DB_FILE" "UPDATE sms SET email_sent = 1 WHERE id = $id;"
        fi
    done
fi