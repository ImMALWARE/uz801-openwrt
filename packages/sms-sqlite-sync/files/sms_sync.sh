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

decode_gsm7() {
    printf '%s\n' "$1" | LC_ALL=C awk '
function hex2dec(value, position, result, digit) {
    result = 0
    for (position = 1; position <= length(value); position++) {
        digit = index("0123456789ABCDEF", toupper(substr(value, position, 1))) - 1
        result = result * 16 + digit
    }
    return result
}
function utf8(codepoint) {
    if (codepoint < 128)
        return sprintf("%c", codepoint)
    if (codepoint < 2048)
        return sprintf("%c%c", 192 + int(codepoint / 64), 128 + codepoint % 64)
    return sprintf("%c%c%c", 224 + int(codepoint / 4096), 128 + int((codepoint % 4096) / 64), 128 + codepoint % 64)
}
function gsm7_character(septet, escaped,    extension) {
    if (escaped) {
        extension[10] = 12
        extension[20] = 94
        extension[40] = 123
        extension[41] = 125
        extension[47] = 92
        extension[60] = 91
        extension[61] = 126
        extension[62] = 93
        extension[64] = 124
        extension[101] = 8364
        return (septet in extension ? utf8(extension[septet]) : "")
    }
    if (septet == 0) return "@"
    if (septet == 1) return utf8(163)
    if (septet == 2) return "$"
    if (septet == 3) return utf8(165)
    if (septet == 4) return utf8(232)
    if (septet == 5) return utf8(233)
    if (septet == 6) return utf8(249)
    if (septet == 7) return utf8(236)
    if (septet == 8) return utf8(242)
    if (septet == 9) return utf8(199)
    if (septet == 10) return "\n"
    if (septet == 11) return utf8(216)
    if (septet == 12) return utf8(248)
    if (septet == 13) return "\r"
    if (septet == 14) return utf8(197)
    if (septet == 15) return utf8(229)
    if (septet == 16) return utf8(916)
    if (septet == 17) return "_"
    if (septet == 18) return utf8(934)
    if (septet == 19) return utf8(915)
    if (septet == 20) return utf8(923)
    if (septet == 21) return utf8(937)
    if (septet == 22) return utf8(928)
    if (septet == 23) return utf8(936)
    if (septet == 24) return utf8(931)
    if (septet == 25) return utf8(920)
    if (septet == 26) return utf8(926)
    if (septet == 28) return utf8(198)
    if (septet == 29) return utf8(230)
    if (septet == 30) return utf8(223)
    if (septet == 31) return utf8(201)
    if (septet == 36) return utf8(164)
    if (septet == 64) return utf8(161)
    if (septet == 91) return utf8(196)
    if (septet == 92) return utf8(214)
    if (septet == 93) return utf8(209)
    if (septet == 94) return utf8(220)
    if (septet == 95) return utf8(167)
    if (septet == 96) return utf8(191)
    if (septet == 123) return utf8(228)
    if (septet == 124) return utf8(246)
    if (septet == 125) return utf8(241)
    if (septet == 126) return utf8(252)
    if (septet == 127) return utf8(224)
    return sprintf("%c", septet)
}
{
    for (position = 1; position <= length($0); position += 2)
        bytes[(position - 1) / 2] = hex2dec(substr($0, position, 2))

    escaped = 0
    for (character = 0; character < character_count; character++) {
        bit_position = start_bit + character * 7
        byte_index = int(bit_position / 8)
        shift = bit_position % 8
        septet = int(bytes[byte_index] / (2 ^ shift)) % 128
        if (shift > 1)
            septet += (bytes[byte_index + 1] % (2 ^ (shift - 1))) * (2 ^ (8 - shift))
        if (septet == 27) {
            escaped = 1
        } else {
            printf "%s", gsm7_character(septet, escaped)
            escaped = 0
        }
    }
}' character_count="$2" start_bit="${3:-0}"
}

save_sms() {
    sms_indexes="$1"
    sms_sender="$2"
    sms_date="$3"
    sms_encoding="$4"
    sms_segments="$5"
    sms_file="$(mktemp /tmp/sms_message.XXXXXX)" || return 1

    for sms_segment in $(printf '%s' "$sms_segments" | tr ',' ' '); do
        sms_data="${sms_segment%%:*}"
        sms_segment="${sms_segment#*:}"
        sms_length="${sms_segment%%:*}"
        sms_offset="${sms_segment#*:}"
        case "$sms_encoding" in
            UCS2) decode_ucs2 "$sms_data" >> "$sms_file" ;;
            GSM7) decode_gsm7 "$sms_data" "$sms_length" "$sms_offset" >> "$sms_file" ;;
        esac
    done
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
function parse_pdu(index_value, pdu, position, smsc_length, first_octet, address_length, address_type, address_bytes, address, pid, dcs, timestamp, user_length, user_data, encoding, udhl, header, header_position, iei, ie_length, reference, total, sequence, payload, text_length, text_bit_offset, header_bits) {
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
    address_bytes = int((address_length + 1) / 2)
    address = (toupper(address_type) == "D0" ? sender_alphanumeric(substr(pdu, position, address_bytes * 2), int(address_bytes * 8 / 7)) : sender_number(substr(pdu, position, address_bytes * 2), address_length, address_type))
    position += address_bytes * 2
    pid = byte_at(pdu, position)
    position += 2
    dcs = byte_at(pdu, position)
    position += 2
    timestamp = received_date(substr(pdu, position, 14))
    position += 14
    user_length = byte_at(pdu, position)
    position += 2

    if (dcs == 8)
        encoding = "UCS2"
    else if (dcs == 0)
        encoding = "GSM7"
    else {
        emit_error(index_value, "Unsupported SMS encoding", pdu)
        return
    }
    user_data = substr(pdu, position, (encoding == "GSM7" ? int((user_length * 7 + 7) / 8) : user_length) * 2)

    reference = "-"
    total = 1
    sequence = 1
    payload = user_data
    text_length = user_length
    text_bit_offset = 0
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
        if (encoding == "GSM7") {
            header_bits = (udhl + 1) * 8
            text_length = user_length - int((header_bits + 6) / 7)
            text_bit_offset = int((header_bits + 6) / 7) * 7
        } else {
            payload = substr(user_data, 3 + udhl * 2)
            text_length = length(payload) / 4
        }
    }

    if ((encoding == "UCS2" && length(payload) % 4 != 0) || total < 1 || sequence < 1 || sequence > total) {
        emit_error(index_value, "Invalid SMS payload or concatenation header", pdu)
        return
    }
    printf "P\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", index_value, address, timestamp, reference, total, sequence, encoding, text_length, text_bit_offset, payload
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
    sms_encoding=""
    sms_segments=""
    sorted_group_file="$group_file.sorted"
    sort -n "$group_file" > "$sorted_group_file"
    while IFS="$(printf '\t')" read -r sequence sms_index sender received_date total encoding sms_length sms_offset payload; do
        [ "$sequence" = "1" ] && {
            sms_sender="$sender"
            sms_date="$received_date"
        }
        sms_indexes="$sms_indexes $sms_index"
        sms_encoding="$encoding"
        sms_segments="$sms_segments${sms_segments:+,}$payload:$sms_length:$sms_offset"
    done < "$sorted_group_file"
    save_sms "$sms_indexes" "$sms_sender" "$sms_date" "$sms_encoding" "$sms_segments"
}

ubus call modem_at exec '{"cmd": "AT+CMGF=0"}' > /dev/null 2>&1
ubus call modem_at exec '{"cmd": "AT+CPMS=\"SM\",\"SM\",\"SM\""}' > /dev/null 2>&1

RAW_JSON=$(ubus call modem_at exec '{"cmd": "AT+CMGL=4"}')
json_load "$RAW_JSON"
json_get_var RAW_TEXT response

work_dir="$(mktemp -d /tmp/sms_pdu.XXXXXX)" || exit 1
records_file="$work_dir/records"
printf '%s\n' "$RAW_TEXT" | tr -d '\r' | parse_pdu_records > "$records_file"

while IFS="$(printf '\t')" read -r record_type sms_index sms_sender sms_date reference total sequence encoding sms_length sms_offset payload; do
    case "$record_type" in
        P)
            if [ "$total" = "1" ]; then
                save_sms "$sms_index" "$sms_sender" "$sms_date" "$encoding" "$payload:$sms_length:$sms_offset"
            else
                group_key="$(printf '%s' "$sms_sender|$reference|$total" | hexdump -v -e '1/1 "%02x"')"
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sequence" "$sms_index" "$sms_sender" "$sms_date" "$total" "$encoding" "$sms_length" "$sms_offset" "$payload" >> "$work_dir/group_$group_key"
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