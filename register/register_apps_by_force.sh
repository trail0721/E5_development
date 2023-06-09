#!/usr/bin/env bash

# https://docs.microsoft.com/en-us/cli/azure/microsoft-graph-migration

set -e

export PATH=~/.local/bin:$PATH

APP_NAME='E5_ALIVE'
CONFIG_PATH='../config'
NAME_GENERATOR='./name_generator/bin/ng'
PERMISSIONS_FILE='./required-resource-accesses.json'
BASE_PORT=$(($(cksum <<<"$USER" | cut -f1 -d' ') % 50000 + 3000))

jq() {
    echo -n "$1" | python3 -c "import sys,json; print(json.load(sys.stdin)$2)"
}

es() {
    echo -n "$1" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))"
}

register_app() {
    order="$1"
    username="$2"
    password="$3"

    config_file="$CONFIG_PATH/app$order.json"
    reply_uri="http://localhost:$((BASE_PORT + order))/"
    identifier="$(cksum <<<"$username" | cut -f1 -d' ')"
    name_prefix="$("$NAME_GENERATOR" "$identifier")"
    real_app_name="${name_prefix}${identifier}"

    # separate multiple accounts
    export AZURE_CONFIG_DIR="/tmp/az-cli/$order"
    mkdir -p "$AZURE_CONFIG_DIR"
    # clear account if exists
    # az account clear

    # login
    # https://docs.microsoft.com/en-us/cli/azure/reference-index?view=azure-cli-latest#az-login
    # ret="$(az login \
    #     --allow-no-subscriptions \
    #     -u "$username" \
    #     -p "$password" 2>/dev/null)"
    # tenant_id="$(jq "$ret" "[0]['tenantId']")"
    az login \
        --allow-no-subscriptions \
        -u "$username" \
        -p "$password" \
        --only-show-errors 1>/dev/null || {
        echo "登录失败，账号或密码错误，或未关闭多因素认证（安全默认值），请进一步阅读英文日志"
        exit 1
    }

    # delete the existing app
    # https://docs.microsoft.com/en-us/cli/azure/ad/app?view=azure-cli-latest#az-ad-app-list
    # https://docs.microsoft.com/en-us/graph/api/application-list?view=graph-rest-1.0&tabs=http#response-1
    has_old_app="false"
    for nm in "$APP_NAME" "$name_prefix"; do
        while true; do
            ret=$(az ad app list --display-name "$nm")
            [ "$ret" = "[]" ] && break

            has_old_app="true"
            # https://docs.microsoft.com/en-us/cli/azure/ad/app?view=azure-cli-latest#az-ad-app-delete
            az ad app delete \
                --id "$(jq "$ret" "[0]['appId']")" \
                --only-show-errors

            sleep 3
        done
    done
    # wait azure system to refresh
    [ "$has_old_app" = "true" ] && sleep 17

    # create a new app
    # https://docs.microsoft.com/en-us/cli/azure/ad/app?view=azure-cli-latest#az-ad-app-create
    # https://docs.microsoft.com/en-us/graph/api/application-post-applications?view=graph-rest-1.0&tabs=http#response-1
    # --identifier-uris api://e5.app \
    # azure-cli version > 2.36.0
    ret="$(az ad app create \
        --display-name "$real_app_name" \
        --web-redirect-uris "$reply_uri" \
        --required-resource-accesses "@$PERMISSIONS_FILE")"

    # azure-cli version <= 2.36.0
    # ret="$(az ad app create \
    #     --display-name "$APP_NAME" \
    #     --reply-urls "$reply_uri" \
    #     --available-to-other-tenants true \
    #     --required-resource-accesses "@$PERMISSIONS_FILE")"

    app_id="$(jq "$ret" "['appId']")"
    # https://docs.microsoft.com/en-us/graph/api/user-list?view=graph-rest-1.0&tabs=csharp#response-1
    # azure-cli version > 2.36.0
    user_id="$(jq "$(az ad user list)" "[0]['id']")"

    # azure-cli version <= 2.36.0
    # user_id="$(jq "$(az ad user list)" "[0]['objectId']")"

    # wait azure system to refresh
    sleep 5

    # set owner
    # https://docs.microsoft.com/en-us/cli/azure/ad/app/owner?view=azure-cli-latest#az-ad-app-owner-add
    az ad app owner add \
        --id "$app_id" \
        --owner-object-id "$user_id" \
        --only-show-errors

    # wait azure system to refresh
    sleep 30

    # grant admin consent
    # https://docs.microsoft.com/en-us/cli/azure/ad/app/permission?view=azure-cli-latest#az-ad-app-permission-admin-consent
    az ad app permission admin-consent \
        --id "$app_id" \
        --only-show-errors

    # generate client secret
    # https://docs.microsoft.com/en-us/cli/azure/ad/app/credential?view=azure-cli-latest#az-ad-app-credential-reset
    # https://docs.microsoft.com/en-us/graph/api/application-addpassword?view=graph-rest-1.0&tabs=http
    ret="$(az ad app credential reset \
        --id "$app_id" \
        --years 100 2>/dev/null)"
    client_secret="$(jq "$ret" "['password']")"

    # wait azure system to refresh
    sleep 30

    # save app details
    # shellcheck disable=SC2086
    cat >"$config_file" <<EOF
{
    "username": "$username",
    "password": $(es $password),
    "client_id": "$app_id",
    "client_secret": "$client_secret",
    "redirect_uri": "$reply_uri",
    "app_name_prefix": "$name_prefix"
}
EOF

    timeout -k 1m 1m node server.js "$config_file" &
    timeout -k 1m 1m node client.js "$config_file"

    grep "refresh_token" "$config_file" >/dev/null ||
        exit 1
}

# rm -rf "$CONFIG_PATH"
# mkdir -p "$CONFIG_PATH"
# chmod +x "$NAME_GENERATOR"

# https://ss64.com/bash/mapfile.html
# mapfile -t users < <(echo -e "$USER")
# mapfile -t passwords < <(echo -e "$PASSWD")
# for ((i = 0; i < "${#users[@]}"; i++)); do
#     {
# can not capture stdout or stderr if set -e is open and
# error occurs in register_app
#         log=$(register_app "$i" "${users[$i]}" "${passwords[$i]}")
#         echo "$log"
#         echo "$log" | grep '注册成功' >/dev/null
#         register_app "$i" "${users[$i]}" "${passwords[$i]}"
#     } &
#     pids[$i]=$!
#     register_app "$i" "${users[$i]}" "${passwords[$i]}" &
# done

# https://stackoverflow.com/questions/356100/how-to-wait-in-bash-for-several-subprocesses-to-finish-and-return-exit-code-0
# https://man7.org/linux/man-pages/man1/wait.1p.html
# ecode=0
# for pid in "${pids[@]}"; do
#     wait $pid || ecode=1
# done

# exit $ecode

main() {
    rm -rf "$CONFIG_PATH"
    mkdir -p "$CONFIG_PATH"
    chmod +x "$NAME_GENERATOR"

    mapfile -t users < <(echo -e "$USER")
    mapfile -t passwords < <(echo -e "$PASSWD")
    for ((i = 0; i < "${#users[@]}"; i++)); do
        register_app "$i" "${users[$i]}" "${passwords[$i]}" &
    done
    wait
}

main
