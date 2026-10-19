# shellcheck shell=bash
# users.sh: admin accounts, SSH keys, the ssh-users group and the root password.

SSH_GROUP=ssh-users
declare -gA PW_HASH=()      # user → crypt hash, filled by the wizard (never saved)
declare -gA KEYS_NEW=()     # user → keys pasted in the wizard (saved to keys/USER.pub on apply)

user_home() { getent passwd "$1" | cut -d: -f6; }

# has_usable_password USER: "P" in passwd -S means a usable password is set.
has_usable_password() { [[ $(passwd -S "$1" 2>/dev/null | awk '{print $2}') == P ]]; }

# Accounts (other than root) that can log in over SSH today: they have keys.
accounts_with_keys() {
  local u uid home
  while IFS=: read -r u _ uid _ _ home _; do
    (( uid >= 1000 && uid < 60000 )) || continue
    if [[ -s $home/.ssh/authorized_keys ]]; then printf '%s\n' "$u"; fi
  done < <(getent passwd)
}

# validate_pubkeys TEXT: every non-empty line must be a public key
# (optionally with options). Private keys are refused outright.
validate_pubkeys() {
  local text=$1 line tmp
  if [[ $text == *"PRIVATE KEY"* ]]; then
    warn "That is a PRIVATE key. Use the .pub file instead, and never share the private one."
    return 1
  fi
  while IFS= read -r line; do
    [[ -z $line || $line == \#* ]] && continue
    if [[ ! $line =~ (^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
      warn "Not a public key line: ${line:0:40}…"
      return 1
    fi
    if command -v ssh-keygen >/dev/null; then
      tmp=$(mktemp); printf '%s\n' "$line" >"$tmp"
      if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"; warn "ssh-keygen rejects this key: ${line:0:40}…"; return 1
      fi
      rm -f "$tmp"
    fi
  done <<<"$text"
}

# Keys for USER come from $SS_CONF_DIR/keys/USER.pub (written by the wizard or
# placed there by you) and, for the primary admin, ADMIN_PUBKEY.
user_keys_source() {
  local u=$1 f="$SS_CONF_DIR/keys/$1.pub" k="" extra
  if [[ -s $f ]]; then k=$(<"$f"); fi
  if [[ -n ${KEYS_NEW[$u]:-} ]]; then k=$(printf '%s\n%s' "$k" "${KEYS_NEW[$u]}"); fi
  if [[ $u == "$(cfg_primary_admin)" && -n ${CFG[ADMIN_PUBKEY]} ]]; then
    extra=${CFG[ADMIN_PUBKEY]}
    if [[ -f $extra ]]; then extra=$(<"$extra"); fi
    k=$(printf '%s\n%s' "$k" "$extra")
  fi
  sed '/^[[:space:]]*$/d' <<<"$k" | awk '!seen[$0]++'
}

# Save keys pasted in the wizard so later runs (and you) can see them.
save_new_keys() {
  local u f
  for u in "${!KEYS_NEW[@]}"; do
    f="$SS_CONF_DIR/keys/$u.pub"
    [[ $SS_DRY_RUN == true ]] && continue
    { if [[ -s $f ]]; then cat "$f"; fi; printf '%s\n' "${KEYS_NEW[$u]}"; } | awk 'NF && !seen[$0]++' >"$f.new"
    chmod 600 "$f.new"; mv -f "$f.new" "$f"
  done
}

user_pw_hash() {
  local u=$1
  if [[ -n ${PW_HASH[$u]:-} ]]; then printf '%s' "${PW_HASH[$u]}"
  elif [[ $u == "$(cfg_primary_admin)" ]]; then printf '%s' "${CFG[ADMIN_PASSWORD_HASH]}"
  fi
}

# users_preflight: refuse before any change if an admin would end up without
# a key (locked out of SSH) or without a password (sudo would not work).
users_preflight() {
  local u errs=() keys home
  for u in ${CFG[ADMIN_USERS]}; do
    keys=$(user_keys_source "$u")
    if [[ -n $keys ]]; then
      validate_pubkeys "$keys" || errs+=("the SSH key for $u is not valid")
    else
      home=$(user_home "$u" 2>/dev/null || true)
      [[ -n $home && -s $home/.ssh/authorized_keys ]] \
        || errs+=("$u has no SSH key (paste one in the wizard, or put it in $SS_CONF_DIR/keys/$u.pub)")
    fi
    if ! is_true "${CFG[ALLOW_NOPASSWD_SUDO]}" && [[ -z $(user_pw_hash "$u") ]] \
       && ! { id "$u" &>/dev/null && has_usable_password "$u"; }; then
      errs+=("$u has no password, so sudo would not work (set one, or ADMIN_PASSWORD_HASH, or ALLOW_NOPASSWD_SUDO=true)")
    fi
  done
  if (( ${#errs[@]} )); then
    printf '%s[x]%s Nothing was changed:\n' "$C_RED" "$C_0" >&2
    printf '      - %s\n' "${errs[@]}" >&2
    return 1
  fi
}

apply_users() {
  local u keys home ak line hash sudoers
  step "Admin accounts"
  run_cmd groupadd -f "$SSH_GROUP"
  for u in ${CFG[ADMIN_USERS]}; do
    if ! id "$u" &>/dev/null; then
      run_cmd adduser --disabled-password --gecos "" "$u"
      log "Created $u"
    fi
    run_cmd usermod -aG "sudo,$SSH_GROUP" "$u"

    hash=$(user_pw_hash "$u")
    if [[ -n $hash ]]; then
      if [[ $SS_DRY_RUN == true ]]; then echo "  would set a password for $u"; else usermod -p "$hash" "$u"; fi
    fi

    sudoers="/etc/sudoers.d/90-server-setup-$u"
    if is_true "${CFG[ALLOW_NOPASSWD_SUDO]}"; then
      printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$u" | write_file "$sudoers" 440
      if [[ $SS_DRY_RUN != true ]] && ! visudo -cf "$sudoers" >/dev/null; then
        rm -f "$sudoers"; die "sudoers check failed for $u"
      fi
      warn "$u can use sudo without a password (ALLOW_NOPASSWD_SUDO=true)."
    elif [[ -e $sudoers ]]; then
      backup_file "$sudoers"; run_cmd rm -f "$sudoers"
    fi

    keys=$(user_keys_source "$u")
    if [[ $SS_DRY_RUN == true ]]; then
      if [[ -n $keys ]]; then echo "  would make sure $(wc -l <<<"$keys") key(s) are in $u's authorized_keys"; fi
      continue
    fi
    home=$(user_home "$u"); ak="$home/.ssh/authorized_keys"
    install -d -m 700 -o "$u" -g "$u" "$home/.ssh"
    if [[ ! -e $ak ]]; then install -m 600 -o "$u" -g "$u" /dev/null "$ak"; fi
    backup_file "$ak"
    while IFS= read -r line; do
      if [[ -n $line ]] && ! grep -qxF -- "$line" "$ak"; then printf '%s\n' "$line" >>"$ak"; fi
    done <<<"$keys"
    chmod 600 "$ak"; chown "$u:$u" "$ak"
    [[ -s $ak ]] || die "$u has no SSH key; stopping before SSH is locked down."
  done
  for u in ${CFG[SSH_USERS]}; do
    if id "$u" &>/dev/null; then run_cmd usermod -aG "$SSH_GROUP" "$u"; fi
  done
}

# Lock root's password only when an admin can still log in at a console with a password.
apply_root_lock() {
  local u ok=""
  [[ $SS_DRY_RUN == true ]] && { echo "  would lock root's password if an admin has a password"; return 0; }
  for u in ${CFG[ADMIN_USERS]}; do
    if has_usable_password "$u"; then ok=$u; break; fi
  done
  if [[ -z $ok ]]; then
    warn "Root's password stays as it is: no admin has a password, so it is your console fallback."
    return 0
  fi
  if [[ $(passwd -S root | awk '{print $2}') != L ]]; then
    step "Locking root's password ($ok can still use sudo and the console)"
    passwd -l root >/dev/null
  fi
}
