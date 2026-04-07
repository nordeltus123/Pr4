#!/bin/bash
# 924567, Estaún Bescós, Julio Pedro, M, 3, A
# 926619, Campo Calvo, Eva Qiuxiang, M, 3, A

#CONSTANTES

readonly UID_MIN=1815 #UID mínimo asignado a los usuarios creados
readonly DIR_BACKUP="/extra/backup" #Directorio donde se guardan los backups
readonly OPCIONES_SSH="-i $HOME/.ssh/id_as_ed25519"

#FUNCIONES

#Devuelve el nombre del fichero de log con la fecha actual
obtener_fichero_log() {
	echo "$(date +%Y_%m_%d)_user_provisioning.log"
}

#Escribe un mensaje por pantalla y lo añade al fichero de log
registrar_mensaje() {
	local mensaje="$1"
	local fichero_log
	fichero_log=$(obtener_fichero_log)
	echo "$mensaje" | tee -a "$fichero_log"
}

#Comprueba que el número de argumentos es exactamente 3
comprobar_num_argumentos() {
	if [[ "$#" -ne 3 ]]; then
		echo "Número incorrecto de párametros"
		exit 1
	fi
}

#Comprueba que la opción es -a o -s
comprobar_opcion() {
	local opcion="$1"
	if [[ "$opcion" != "-a" && "$opcion" != "-s" ]]; then
		echo "Opción invalida" >&2
		exit 1
	fi
}

#Comprueba que el fichero de entrada existe y tiene permisos de lectura
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

#Comprueba que una máquina remota es accesible por ssh
comprobar_maquina() {
	local ip="$1"
	# Usamos -n para evitar que ssh consuma la entrada estándar del bucle
	ssh -n $OPCIONES_SSH "as@$ip" "true" 2>/dev/null
}

anadir_usuarios() {
	local fichero_usuarios="$1"
	local fichero_maquinas="$2"

	# Leemos el fichero de IPs
	while IFS= read -r ip || [ -n "$ip" ]; do
		ip="${ip%$'\r'}"
		if [[ -z "$ip" ]]; then 
            continue
        fi

		# Comprobamos que la máquina es accesible
		if ! comprobar_maquina "$ip"; then
			registrar_mensaje "$ip no es accesible"
			continue
		fi

		# Leemos el fichero de usuarios, redirigimos el fichero como entrada del bucle y separamos campos por coma
		while IFS=',' read -r username password fullname || [ -n "$username" ]; do
			username="${username%$'\r'}"
			password="${password%$'\r'}"
			fullname="${fullname%$'\r'}"

            #Comprobamos que ninguno de los 3 campos esté vacío
			if [[ -z "$username" || -z "$password" || -z "$fullname" ]]; then
				registrar_mensaje "Campo invalido"
				continue
			fi 

			# Si el usuario ya existe en la máquina remota, lo notificamos y continuamos
			if ssh -n $OPCIONES_SSH "as@$ip" "id $username &>/dev/null"; then 
				registrar_mensaje "El usuario $username ya existe"
				continue
			fi

			# Ejecutamos los comandos en remoto pasando un Here Document a sudo bash
			ssh $OPCIONES_SSH "as@$ip" "sudo bash -s" <<-EOF
				uid=$UID_MIN
				while getent passwd | awk -F: '{print \$3}' | grep -q "^\${uid}\$"; do
					uid=\$((uid + 1))
				done

				groupadd "$username" 2>/dev/null
				useradd -m -k /etc/skel -u "\$uid" -g "$username" -c "$fullname" "$username"
				echo "$username:$password" | chpasswd
				chage -M 30 "$username"
			EOF

			registrar_mensaje "$username ha sido creado en $ip"
		done < "$fichero_usuarios"
	done < "$fichero_maquinas"
}

borrar_usuarios() {
	local fichero_usuarios="$1"
	local fichero_maquinas="$2"
	local archivolog="$(obtener_fichero_log)"

	while IFS= read -r ip || [ -n "$ip" ]; do
		ip="${ip%$'\r'}"
		if [[ -z "$ip" ]]; then 
            continue
        fi

		if ! comprobar_maquina "$ip"; then
			echo "$ip no es accesible" >> "$archivolog"
			echo "$ip no es accesible"
			continue
		fi

		# Creamos el directorio de backups de forma incondicional
		ssh -n $OPCIONES_SSH "as@$ip" "sudo mkdir -p $DIR_BACKUP"

		# Para extraer solo el primer campo
		awk -F',' '{print $1}' "$fichero_usuarios" | while read user
		do	
			user="${user%$'\r'}"
			if [[ -z "$user" ]]; then 
                continue 
            fi

			# Comprobamos si el usuario existe remotamente
			if ssh -n $OPCIONES_SSH "as@$ip" "id $user &>/dev/null"; then	
				
				# Backup y borrado en remoto 
				ssh $OPCIONES_SSH "as@$ip" "sudo bash -s" <<-EOF
					tar -cf "$DIR_BACKUP/$user.tar" /home/$user 2>/dev/null
					if [[ \$? -ne 0 ]]; then
						exit 1
					fi
					userdel -r "$user"
				EOF
				# Comprobamos el código de salida del bloque ssh
				if [[ $? -eq 0 ]]; then
					echo "Usuario $user eliminado en $ip." >> "$archivolog"
				else
					echo "Error en backup $user. No se elimina el usuario." >> "$archivolog"
				fi
			fi
		done
	done < "$fichero_maquinas"
}

#PROGRAMA PRINCIPAL 

comprobar_num_argumentos "$@"

comprobar_opcion "$1"
OPCION="$1"
FICHERO_USUARIOS="$2"
FICHERO_MAQUINAS="$3"

comprobar_fichero_entrada "$FICHERO_USUARIOS"
comprobar_fichero_entrada "$FICHERO_MAQUINAS"

#Ejecutamos la operación correspondiente según la opción
case "$OPCION" in
	-a)
		anadir_usuarios "$FICHERO_USUARIOS" "$FICHERO_MAQUINAS"
		;;
	-s)
		borrar_usuarios "$FICHERO_USUARIOS" "$FICHERO_MAQUINAS"
		;;
esac 

exit