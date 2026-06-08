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

ubus call modem_at exec '{"cmd": "AT+CMGF=1"}' > /dev/null 2>&1
ubus call modem_at exec '{"cmd": "AT+CPMS=\"SM\",\"SM\",\"SM\""}' > /dev/null 2>&1
ubus call modem_at exec '{"cmd": "AT+CNMI=2,1,1,0,0"}' > /dev/null 2>&1

RAW_JSON=$(ubus call modem_at exec '{"cmd": "AT+CMGL=\"ALL\""}')
json_load "$RAW_JSON"
json_get_var RAW_TEXT response

echo "$RAW_TEXT" | tr -d '\r' | awk '
function hex2dec(h,   i, l, r, c) {
    l = length(h); r = 0;
    for(i=1; i<=l; i++) {
        c = index("0123456789ABCDEF", toupper(substr(h, i, 1))) - 1;
        r = r * 16 + c;
    }
    return r;
}
BEGIN { state = 0 }
/^$/ || /^OK$/ { next }
/^\+CMGL:/ {
    split($0, parts, ",")
    idx = parts[1]; sub(/.*\+CMGL:[ \t]*/, "", idx)
    sender = parts[3]; gsub(/"/, "", sender)
    date_str = parts[5] "," parts[6]; gsub(/"/, "", date_str)

    if (idx == "") {
        raw = $0; gsub(/\x27/, "\x27\x27", raw)
        printf "ERROR|0|INSERT INTO errors (error_type, raw_data, description) VALUES (\x27PARSE_FAIL\x27, \x27%s\x27, \x27Invalid +CMGL format\x27);\n", raw
    } else {
        state = 1
    }
    next
}
state == 1 {
    msg_hex = $0
    decoded = ""
    is_hex = (msg_hex ~ /^[0-9A-Fa-f]+$/ && length(msg_hex) % 4 == 0)

    if (is_hex) {
        for(i=1; i<=length(msg_hex); i+=4) {
            d = hex2dec(substr(msg_hex, i, 4));
            if(d < 128) {
                decoded = decoded sprintf("%c", d);
            } else if(d < 2048) {
                decoded = decoded sprintf("%c%c", 192 + int(d/64), 128 + d%64);
            } else {
                decoded = decoded sprintf("%c%c%c", 224 + int(d/4096), 128 + int((d%4096)/64), 128 + d%64);
            }
        }
    } else {
        decoded = msg_hex
    }

    gsub(/\x27/, "\x27\x27", decoded)
    gsub(/\x27/, "\x27\x27", sender)

    printf "INSERT|%s|INSERT INTO sms (sender, message, receive_date) VALUES (\x27%s\x27, \x27%s\x27, \x27%s\x27);\n", idx, sender, decoded, date_str
    state = 0
    next
}
' | while IFS='|' read -r action idx sql; do
    if [ "$action" = "INSERT" ]; then
        if sqlite3 "$DB_FILE" "$sql"; then
            ubus call modem_at exec "{\"cmd\": \"AT+CMGD=$idx\"}" > /dev/null 2>&1
        else
            err_sql="INSERT INTO errors (error_type, raw_data, description) VALUES ('DB_ERROR', '$idx', 'Failed to save SMS index $idx to DB');"
            sqlite3 "$DB_FILE" "$err_sql"
        fi
    elif [ "$action" = "ERROR" ]; then
        sqlite3 "$DB_FILE" "$sql"
    fi
done

if [ "$enable_email" = "1" ] && [ -n "$smtp_server" ] && [ -n "$email_to" ]; then
    sqlite3 -separator '|' "$DB_FILE" "SELECT id, sender, message FROM sms WHERE email_sent = 0;" | while IFS='|' read -r id sender msg; do
        TMPBODY=$(mktemp /tmp/sms_body.XXXXXX)
        printf '%s' "$msg" > "$TMPBODY"
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
            $SSL_FLAG -ehlo -auth -user "$smtp_user" > /dev/null 2>&1
        RET=$?
        rm -f "$TMPBODY"
        if [ $RET -eq 0 ]; then
            sqlite3 "$DB_FILE" "UPDATE sms SET email_sent = 1 WHERE id = $id;"
        fi
    done
fi