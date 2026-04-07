#!/bin/bash
# 924567, Estaún Bescós, Julio Pedro, M, 3, A
# 926619, Campo Calvo, Eva Qiuxiang, M, 3, A
 
# CONSTANTES
readonly UID_MIN=1815                  # UID mínimo asignado a los usuarios creados
readonly BACKUP_DIR="/extra/backup"    # Directorio donde se guardan los backups
readonly SSH_KEY="$HOME/.ssh/id_as_ed25519"  # Clave privada para autenticación SSH
readonly SSH_USER="as"                 # Usuario remoto con el que conectar
 
# FUNCIONES
 
# Devuelve el nombre del fichero de log con la fecha actual
obtener_fichero_log() {
	echo "$(date +%Y_%m_%d)_user_provisioning.log"
}
 
# Escribe un mensaje por pantalla y lo añade al fichero de log (local)
registrar_mensaje() {
	local msg="$1"
	local logfile
	logfile=$(obtener_fichero_log)
	echo "$msg" | tee -a "$logfile"
}
 
# Comprueba que el script se ejecuta con privilegios de root
comprobar_privilegios() {
	if [[ "$(id -u)" -ne 0 ]]; then
		echo "Este script necesita privilegios de administracion"
		exit 1
	fi
}
 
# Comprueba que el número de argumentos es exactamente 3
comprobar_num_argumentos() {
	if [[ "$#" -ne 3 ]]; then
		echo "Número incorrecto de párametros"
		exit 1
	fi
}
 
# Comprueba que la opción es -a o -s
comprobar_opcion() {
	local opt="$1"
	if [[ "$opt" != "-a" && "$opt" != "-s" ]]; then
		echo "Opción invalida" >&2
		exit 1
	fi
}
 
# Comprueba que el fichero de entrada existe y tiene permisos de lectura
comprobar_fichero_entrada() {
	local fichero="$1"
	if [[ ! -f "$fichero" ]]; then
		echo "El fichero '$fichero' no existe o no es un fichero regular" >&2
		exit 1
	fi
	if [[ ! -r "$fichero" ]]; then
		echo "El fichero '$fichero' no tiene permisos de lectura" >&2
		exit 1
	fi
}
 
# Comprueba que la máquina remota es accesible vía SSH
comprobar_maquina() {
	local ip="$1"
	ssh -i "$SSH_KEY" \
		-o BatchMode=yes \
		-o ConnectTimeout=5 \
		-o StrictHostKeyChecking=no \
		"${SSH_USER}@${ip}" "true" &>/dev/null
	return $?
}
 
# Ejecuta un bloque de código como root en la máquina remota vía SSH + sudo
ejecutar_remoto() {
	local ip="$1"
	local cmd="$2"
	ssh -i "$SSH_KEY" \
		-o BatchMode=yes \
		-o ConnectTimeout=5 \
		-o StrictHostKeyChecking=no \
		"${SSH_USER}@${ip}" "sudo bash -s" <<< "$cmd"
}
 
# Devuelve el primer UID libre >= UID_MIN en la máquina remota
obtener_siguiente_uid_remoto() {
	local ip="$1"
	ejecutar_remoto "$ip" "
		uid=$UID_MIN
		while getent passwd | awk -F: '{print \$3}' | grep -q \"^\${uid}\$\"; do
			uid=\$((uid + 1))
		done
		echo \$uid
	"
}
 
# Añade usuarios del fichero en una máquina remota
anadir_usuarios_remoto() {
	local ip="$1"
	local fichero="$2"
 
	while IFS=',' read -r username password fullname || [ -n "$username" ]; do
		# Eliminamos \r por los ficheros creados en Windows
		username="${username%$'\r'}"
		password="${password%$'\r'}"
		fullname="${fullname%$'\r'}"
 
		# Comprobamos que ninguno de los 3 campos esté vacío
		if [[ -z "$username" || -z "$password" || -z "$fullname" ]]; then
			registrar_mensaje "[$ip] Campo invalido"
			continue
		fi
 
		# Comprobamos si el usuario ya existe en la máquina remota
		if ejecutar_remoto "$ip" "id '$username'" &>/dev/null; then
			registrar_mensaje "[$ip] El usuario $username ya existe"
			continue
		fi
 
		# Obtenemos el primer UID libre en la máquina remota
		local new_uid
		new_uid=$(obtener_siguiente_uid_remoto "$ip")
 
		# Creamos grupo y usuario en la máquina remota
		ejecutar_remoto "$ip" "
			groupadd '$username' 2>/dev/null
			useradd -m \
				-k /etc/skel \
				-u '$new_uid' \
				-g '$username' \
				-c '$fullname' \
				'$username'
			echo '${username}:${password}' | chpasswd
			chage -M 30 '$username'
		"
 
		if [[ $? -eq 0 ]]; then
			registrar_mensaje "[$ip] $username ha sido creado"
		else
			registrar_mensaje "[$ip] Error al crear el usuario $username"
		fi
 
	done < "$fichero"
}
 
# Borra usuarios del fichero en una máquina remota
borrar_usuarios_remoto() {
	local ip="$1"
	local fichero="$2"
 
	while IFS=',' read -r username _ _ || [ -n "$username" ]; do
		username="${username%$'\r'}"
 
		if [[ -z "$username" ]]; then
			continue
		fi
 
		# Comprobamos si el usuario existe en la máquina remota
		if ! ejecutar_remoto "$ip" "id '$username'" &>/dev/null; then
			registrar_mensaje "[$ip] El usuario $username no existe"
			continue
		fi
 
		# Creamos backup y borramos el usuario en la máquina remota
		ejecutar_remoto "$ip" "
			mkdir -p '$BACKUP_DIR'
			tar -cf '${BACKUP_DIR}/${username}.tar' '/home/${username}' 2>/dev/null
			if [[ \$? -ne 0 ]]; then
				echo 'Error en backup $username. No se elimina el usuario.'
				exit 1
			fi
			userdel -r '$username'
		"
 
		if [[ $? -eq 0 ]]; then
			registrar_mensaje "[$ip] Usuario $username eliminado."
		else
			registrar_mensaje "[$ip] Error en backup $username. No se elimina el usuario."
		fi
 
	done < "$fichero"
}
 
# Itera sobre el fichero de máquinas y aplica la operación en cada una
procesar_maquinas() {
	local opcion="$1"
	local fichero_usuarios="$2"
	local fichero_maquinas="$3"
 
	while IFS= read -r ip || [ -n "$ip" ]; do
		ip="${ip%$'\r'}"
 
		# Saltamos líneas vacías
		[[ -z "$ip" ]] && continue
 
		# Comprobamos conectividad SSH
		if ! comprobar_maquina "$ip"; then
			registrar_mensaje "$ip no es accesible"
			continue
		fi
 
		# Ejecutamos la operación correspondiente
		case "$opcion" in
			-a)
				anadir_usuarios_remoto "$ip" "$fichero_usuarios"
				;;
			-s)
				borrar_usuarios_remoto "$ip" "$fichero_usuarios"
				;;
		esac
 
	done < "$fichero_maquinas"
}
 
# PROGRAMA PRINCIPAL
 
comprobar_privilegios
comprobar_num_argumentos "$@"
comprobar_opcion "$1"
 
OPTION="$1"
USERS_FILE="$2"
MACHINES_FILE="$3"
 
comprobar_fichero_entrada "$USERS_FILE"
comprobar_fichero_entrada "$MACHINES_FILE"
 
procesar_maquinas "$OPTION" "$USERS_FILE" "$MACHINES_FILE"
 
exit 0