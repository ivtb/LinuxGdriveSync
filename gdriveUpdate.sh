#!/bin/bash
#
#  Questo script controlla se qualcosa è cambiato in una lista di directory
#+ figlie di una directory (in questo caso $HOME/gdrive).
#+ Se qualcosa è stato modificato, è eseguito rclone per
#+ sincronizzare la directory locale con il cloud
#
# 2.1: Added log file creation
# 2.2: Added function logRotate: Quando il file di log è più grande di 50kB,
#      lo comprimo e rinomino. Così il file di log resta leggibile
# 2.3: Aggiunta la possibilita' di listare il file di log con il paramentro
#      showlog
# 2.4: Aggiunto descrizione nel log file su quali file sono stati cancellati
#      e copiati (nel caso non ci siano variazioni, il log rimane uguale
#      a prima)
# 2.5: Aggiunto un parametro: check. Esegue rclone e confronta source e target,
#      ma non fa nulla. Il parametro check e' stato sostituito con loccheck
# 2.6  Aggiunta la funz. syncExecutable() che copia questo script in ~/bin,
#      usando un comando at: lo script e' copiato in ritardo, così da non
#      modificarlo mentre lo si sta eseguendo
# 2.7 Sync con il nas tramite il parametro syncnas (funzione syncNas)
# 3.0 gestione variabili con file di configurazione, per gestire in modo
#     differente host differenti. Si basa sulla variabile $HOSTNAME
# 3.1 Aggiungo l'opzione --copy-links a rclone, per gestire i link,
#     che vengono copiati e sincronizzati
# 3.2 Aggiunta la funzione "integrity", che controlla la data e la dimensione
#     dei file in locale e sul cloud

check_param () {
   #+ Questa funzione controlla che i parametri siano corretti
   local -r numPar=$1
   local -r valPar="$2"
   local par1=""
   local par2=""

   case "${numPar}" in
      1)
         [ "${valPar}" = "up" ]      || [ "${valPar}" = "down" ] || \
            [ "${valPar}" = "check" ]   || [ "${valPar}" = "loccheck" ] ||\
            [ "${valPar}" = "showlog" ] || [ "${valPar}" = "syncnas" ] || \
            [ "${valPar}" = "integrity" ] \
            || return 1
      ;;
      2)
         par1=$(echo "${valPar}" | awk '{print $1}' )
         par2=$(echo "${valPar}" | awk '{print $2}' )
         if [[ "${par1}" != "up" && "${par1}" != "down" ]] ; then
            return 1
         else
            [ "${par2}" != "--dry-run" ] && return 1
         fi
      ;;
      *)
         return 1
      ;;
   esac
   return 0
}

logRotate () {
   # La funzione controlla che il file di log non sia piu' grande di $maxsize
   # Se lo e', lo comprime, lo rinomina con la data e ne crea uno vuoto
   local -r logfile=$1  # Nome del file di log
   local today
   local actualFileSize #File size del file di log
   local -r maxsize=51200

   today=$( date +"%F" )
   actualFileSize=$(stat --format="%s" "${logfile}" )

   if (( actualFileSize > maxsize )) ; then
      # il file è più grande di maxmyDirssize, lo comprimo e lo salvo con modificata
      zstd "${logfile}" -o "${logfile}_${today}.zst"
      \rm "${logfile}"
      touch "${logfile}"
   fi
}

listLog () {
   # Lista il file di log, quando il parametro "showlog" è passato allo script
   local -r logfile=$1
   if [ ! -r "${logfile}" ] ; then
      echo "Errore: Il file di log non e' disponibile o non hai i permessi per"
      echo "leggerlo"
      echo "Il file di log dovrebbe essere disponibile qui: ${logfile}"
      exit 11
   fi
   less "${logfile}"
}

syncExecutable () {
   local -r toDir="$1"
   local -r abspath="$2"
   # Copio l'eseguibile gdriveUpdate.sh appena copiato dal cloud in $toDir.
   # Lo copio solo se la versione in $toDir e' diversa. $toDir e' solitamente
   # ~/bin.
   # Uso "at" per essere sicuro che il file sia copiato quando la sua
   # esecuzione sia finita. Altrimenti, se il processo di sync con googledrive
   # aggiornasse anche questo script, potrei avere degli errori

   if ! cmp --silent "${abspath}" "${toDir}"/$(basename "${abspath}") ; then
      at now + 2 min << EOC 2> /dev/null
      /usr/bin/cp "${abspath}" "${toDir}"
EOC
   fi
}

syncNas () {
  # Sincroizzo il contenuto della directory locale con il nas, se presente
  # La variabile $nas contiene l'indiriizo ip del nas, e va quindi cambiata
  # se il nas ha indirizzo diverso
   nas=192.168.178.222
   syncfrom="${HOME}/gdrive/"
   syncto="/nas/DocSw/Repo/gdrive"
   if ! ping -c 2 "${nas}" > /dev/null ; then
      cat << EOMESSAGE
      ERRORE: Il nas non e' raggiungibile
      Controlla che sia acceso e in rete, ed esegui di nuovo
      questo script
EOMESSAGE
      exit 1
   fi
   echo ""
   echo -e "${GREEN}Nas ${nas} acceso e raggiungibile${Z}"
   echo -e "${PURPLE}Sincronizzo ${syncfrom} verso ${syncto}${Z}"
   rsync --verbose  \
      --progress  \
      --stats \
      --recursive\
      --times\
      --links\
      --delete "${syncfrom}" "${syncto}"
}
cleanup () {
   local -r logRem="/tmp/remote_$$.log"
   local -r logLoc="/tmp/localDisk_$$.log"
   rm -f "${logRem}" "${logLoc}"
}

integrity () {
   # la funz. usa "rclone lsl" per listare i file nella dir locale e remota
   # Poi, con un comado sdiff si listano le differenze, con data e dimensione
   # Questo aiuta a capire quale file sia piu' nuovo e come sincronizzare
   # L'output e' quello di sdiff, quindi sulla stessa riga vedi le info per
   # il file locale e remoto.
   # Attenzione: se in una delle due dir un file e' mancante, l'output
   # non dara' i file sulla stessa linea, c'è un disallineamneto.
   # Analizza attentamente l'output!!!!
   local -r locPath="$1"
   local -r remPath="$2"
   local -r fileToCheck="$3"
   local curDir
   # file di log temporanei:
   logRem="/tmp/remote_$$.log"
   logLoc="/tmp/localDisk_$$.log"

   trap cleanup  EXIT

   for curDir in ${fileToCheck} ; do
      echo -e "${BLU}Controllo la dir ${GREEN}${curDir}${BLU} in locale...${Z}"
      rclone lsl --copy-links "${locPath}/${curDir}" | \
         awk '{a=substr($3,1,8); printf"%-30s %-8s %s %s\n", $4, $1, $2,a}' | \
         sort > "${logLoc}"

      echo -e "${BLU}Controllo la dir ${GREEN}${curDir}${BLU} in remoto...${Z}"
      rclone lsl --copy-links "${remPath}:${curDir}" | \
         awk '{a=substr($3,1,8); printf"%-30s %-8s %s %s\n", $4, $1, $2,a}' | \
         sort > "${logRem}"

      echo "Differenze:"
      echo "Local disk ---> Remote site"
      if  sdiff -s  "${logLoc}" "${logRem}" ; then
         echo -e "${GREEN}Non si sono riscontrate differenze${Z}"
      fi
      echo "---"
      echo ""
   done
   cleanup
}
################################################################################
####                              INIZIO SCRIPT                            #####
################################################################################
scriptRelease="3.2"
gdriveBaseDir=${HOME}/gdrive  # Directory base dove salvi il contenuto di gdrive
                              #+ in locale
gdriveName="gdrive"           # Questo e' il nome con cui hai configurato rclone
#                               per accedere al cloud (in questo caso di google)
#                               Info in rclone .conf
export gdriveBaseDir          # Esporto la variabile, cosi' il valore e'
#+                              disponibile nel file di configurazione, che
#+                              viene caricato con un source
absoluteScriptPath=${gdriveBaseDir}/prog/bash/gdrivesync/$(basename "$0")
configFile=$(dirname "${absoluteScriptPath}")/cfg/$(basename "${absoluteScriptPath}" | \
   awk -F. '{print $1}').cfg
#
# Le variabili myDirs, m5Dir e log sono definite nel file di configurazione.
#+ Qui sono settate vuote, per aggiungere i commenti e per non fare dare errore
#+ in caso venga usato shellcheck, per controllare la sintassi dello script
myDirs=""   # Directory da sincronizzare in gdrive. In questo modo
#+            non sincronizzi l'intero gdrive, ma solo quello
#+            che ti interessa
md5Dir=""   # Directory dove salvare i file MD5. NON SALVARLI
#+            nella directory che analizzi, altrimenti la
#+            sincronizzerai OGNI VOLTA, dato che editi un
#+            file al suo interno
log=""      # path per il file di log

# Carico i valori delle variabili presenti nel file di configurazione
if [ -r "${configFile}" ] ; then
   # shellcheck source=/home/ivan/gdrive/prog/bash/gdrivesync/cfg/gdriveUpdate.cfg
   . "${configFile}"
   if [ "${hostNotFound}" = "true" ] ; then
      echo "File di configurazione errato."
      echo "Host ${HOSTNAME} non trovato in ${configFile}"
      exit 10
   fi
else
   echo "${configFile} non trovato"
   exit 7
fi
dryrun=""                       # Questa variabile puo' essere vuota o
#+                                contenere la string "--dry-run". Se non vuota,
#+                                allora rclone verra' simulato, ma non
#+                                eseguira' il sync
RED="\e[0;31m"                  # Scrive rosso sul terminale
GREEN="\e[0;32m"
BLU="\e[0;34m"
PURPLE="\e[0;35m"
Z="\e[0m"                       # Fine testo colorato per il terminale

echo -e "\n"

if ! check_param "$#" "$*" ; then
   echo ""
   echo -e "${RED}ERRORE: Paramentro/i non valido/i${Z}"
   echo "Lo script DEVE essere eseguito con uno o due parametri"
   echo "Sintassi:"
   echo "$0 [ up | down | check | loccheck | showlog | integrity ] <--dry-run>"
   echo "Quando il primo parametro e'"
   echo "up:       la sincronizzazione verra' eseguita dal disco locale al cloud"
   echo "down:     la sincronizzazione verra' eseguita dal cloud al disco locale"
   echo "loccheck: Si controlla solo se qualcosa è stato modificato nelle dir"
   echo "          locali senza eseguire rclone"
   echo "check:     Si controlla, tramite rclone, se ci siano differenze tra le"
   echo "           dir locali e quelle remote. Non si esegue la sincronizzazione"
   echo "syncnas:   La directory locale di gdrive e' sincronizzata con il"
   echo "           NAS. Se il NAS non è' raggiungibile, si ottiene un errore"
   echo "integrity: Si esegue un check tramite rclone sui file locali e remoti"
   echo "           e si mostrano a video i risultati. Quando un file e'"
   echo "           mancante in locale o in remoto, fate molta attenzione ai"
   echo "           nomi dei file. L'output e' quello del comando sdiff"
   echo "showlog:   Viene listato il file di log"
   echo "--dry-run: Parametro opzionale, valido solo se il primo parametro e'"
   echo "           up o down. Quando presente, il processo di up and down viene"
   echo "           simulato: utile per vedere che cosa succede prima di"
   echo "            eseguire veramente la sincronizzazione"
   exit 1
else
   [ "$2"z = "--dry-runz" ] && dryrun="--dry-run"
fi

# Se e' la prima volta che eseguo lo script, la directory dove salvare i checksum
#+ potrebbe non esistere. Controllo e, se necessario, la creo
[ -d "${md5Dir}" ] || mkdir -p "${md5Dir}"

logRotate "${log}"

case $1 in
   "showlog")
      # Passato il parametro showlog. Mostro il log ed esco
      # Non ho aggiunto il controllo di showlog nel case sotto, per evitare di
      # scrivere nel file di log, quando voglio solo leggerlo.
      listLog "${log}"
      exit 0
   ;;
   "integrity")
      integrity "${gdriveBaseDir}" "${gdriveName}" "${myDirs}"
      exit 0
   ;;
esac

echo -e  "Sync iniziata: $(date)" | tee -a "${log}"
echo "Script release: ${scriptRelease}"
rclone --version | grep ^rclone | awk '{printf"Versione rclone: %s\n", $2}'

if [ -n "${dryrun}" ] ; then
   echo -e "${RED}ATTENZIONE: La sincronizzazione non sara' effettuata: questo e' un DRY RUN ${Z}"
   echo "Puoi controllare i log per vedere quello che succederebbe"
fi
# Per capire se qualche file e' cambiato genero un md5, usando uno "stat" su tutti i file
#+ della directory da investigare. In questo modo sono sicuro che se md5 e' cambiato,
#+ la directory e il suo contenuto hanno subito una modifica, e quindi sincronizzo. Altrimenti
#+ non faccio nulla.
#+ Per generare l'md5 scarto la prima riga del report degli stat, perche' la prima riga
#+ fa riferimento alla directory radice, che cambia anche solo entrandoci. Uso il comando
#+ tail -n +2 (tutto il file eccetto la prima linea)

# La for nel case controlla tutte e sole le directory in $myDirs.
#+ Se trova una differenza esegue un rclone su ogni directory
#+ Il file md5 viene salvato una dir sopra, altrimenti, ogni volta che eseguo questo script,
#+ modificando un file nella dir che analizzo, questa verrebbe sempre sincronizzata.
case $1 in
   "up")
      echo -e "${PURPLE}*****************************************************************************"
      echo -e "***                Inizio sincronizzazione in Upload                      ***"
      echo -e "*****************************************************************************${Z}"

      for curDir in ${myDirs} ; do
         echo -e "${BLU}================================================="
         echo -e "=== Analisi della dir: ${GREEN}${curDir}${Z}"
         echo -e "${BLU}=================================================${Z}"
         md5file=${md5Dir}/md5sum_${curDir}
         #  Se esite un file md5, lo salvo, con prev come suffisso.
         [ -e "${md5file}" ] &&  mv "${md5file}" "${md5file}_prev"
         # Se eseguo un dry run, copio il file md5 originale, in modo da poterlo copiare
         #+ indietro. In questo modo, un dry-run non pregiudichera' lo stato della
         #+ sincronizzazione
         [ -n "${dryrun}" ] && [ -e "${md5file}_prev" ] && cp "${md5file}_prev" "${md5file}_dryrun"
         #
         #  Uso un find per listare tutti i file nella directory corrente. Da questa
         #+ lista, genero una firma md5. Se questa firma è diversa dalla precedente, sono sicuro
         #+ che qualche file è stato aggiunto/cancellato/modificato, e procedo al sync
         find "${gdriveBaseDir}/${curDir}" -exec stat --format="%a %B %D %g %i %n %s %u %y %z" {} \; | \
            tail -n +2 | md5sum > "${md5file}"
         if [[ -e "${md5file}" && -e "${md5file}_prev" ]] ; then
            if ! diff "${md5file}" "${md5file}_prev" > /dev/null ; then
               # Qualcosa è cambiato, faccio il sync
               # Se in dry run, rinomino il file prev con il nome originale, cosi' la
               # prossima volta, tutto funziona come se il dry run non fosse mai stato eseguito
               echo -e "${RED}file diversi in ${curDir} ${Z}"
               echo "eseguo:"
               echo "rclone -v ${dryrun} sync  ${gdriveBaseDir}/${curDir} ${gdriveName}:${curDir}"
               printf "Dir %-20s: Sync executing ==> Syncro UP %s\n" "${curDir}" "${dryrun}" >> "${log}"
               # NON METTERE tra doppi apici la variabile ${dryrun}, altrimenti rclone la interpreta come
               #+ stringa, sebbene vuota, e la interpreta come un parametro, dando errore!!!!!!!!
               rclone -v  sync  "${gdriveBaseDir}/${curDir}" "${gdriveName}:${curDir}" --copy-links ${dryrun} 2>&1 | tee "${log}_tmp"
               awk '/: Copied/ || /: Deleted/ || /: Updated/ || /: Skipped/ {printf" --- %s\n", $0}' "${log}_tmp" >> "${log}"
               rm -f "${log}_tmp"
               echo -e "\n"
            else
               echo -e "${GREEN}Nulla e' cambiato nella directory \"${curDir}\" dall'ultima"
               echo -e "sincronizzazione${Z}"
               printf "Dir %-20s: Sync NOT executed (nothing changed) ==> Syncro UP %s\n" "${curDir}" "${dryrun}" >> "${log}"
            fi
            # Se in dry run, rinomino il file prev con il nome originale, cosi' la
            # prossima volta, tutto funziona come se il dry run non fosse mai stato eseguito
            [ -n "${dryrun}" ] && mv "${md5file}_dryrun" "${md5file}"
         else
            echo "I file md5 di controllo delle directory non erano presenti"
            echo "Presumibilmente questa è la prima volta che sincronizzi"
            echo "la dir ${gdriveBaseDir}/${curDir}"
            echo -e  "${RED}Questa dir NON verra' sincronizzata${Z}"
            echo "======================================================================="
            echo "== Controlla prima di sincronizzare, perche' se la direcory locale   =="
            echo "== fosse vuota, cancelleresti TUTTI I FILE su gdrive!!!!!!           =="
            echo "======================================================================="
            echo ""
         fi
      done
      syncExecutable ~/bin "${absoluteScriptPath}"
   ;;
   "down")
      # Qui non faccio controlli, ma eseguo direttamente il comando rclone,
      #+ perché non posso sapere se qualcosa sia cambiato sul server
      echo -e "${PURPLE}*****************************************************************************"
      echo -e "***                Inizio sincronizzazione in Download                    ***"
      echo -e "*****************************************************************************${Z}"
      for curDir in ${myDirs} ; do
         echo -e "${BLU}================================================="
         echo -e "=== Analisi della dir: ${GREEN}${curDir}${Z}"
         echo -e "${BLU}=================================================${Z}"
         md5file="${md5Dir}/md5sum_${curDir}"
         echo "Eseguo:"
         echo -e "${RED}rclone -v ${dryrun} sync  ${gdriveName}:${curDir} ${gdriveBaseDir}/${curDir}${Z}"
         printf "Dir %-20s: Sync executing ==> Syncro DOWN %s\n" "${curDir}" "${dryrun}"  >> "${log}"
         # NON METTERE tra doppi apici la variabile ${dryrun}, altrimenti rclone la interpreta come
         #+ stringa, sebbene vuota, e la interpreta come un parametro, dando errore!!!!!!!!
         rclone -v sync  "${gdriveName}:${curDir}" "${gdriveBaseDir}/${curDir}" ${dryrun} --copy-links 2>&1 | tee "${log}_tmp"
         awk '/: Copied/ || /: Deleted/ || /: Updated/ || /: Skipped/ {printf" --- %s\n", $0}' "${log}_tmp" >> "${log}"
         rm -f "${log}_tmp"
         if [[ -z "${dryrun}" ]] ; then
            # Non sono in un dry-run, così calcolo l'md5. In questo modo se eseguo
            #+ lo script con parametro up, e non ho editato nulla in una dir,
            #+ evito di sincronizzarla.
            find "${gdriveBaseDir}/${curDir}" -exec stat --format="%a %B %D %g %i %n %s %u %y %z" {} \; | tail -n +2 | md5sum > "${md5file}"
         fi
         echo ""
      done
      syncExecutable ~/bin "${absoluteScriptPath}"
   ;;
   "check")
      # Eseguo rclone con parametro check, che controlla ma non fa nulla
      echo -e "${PURPLE}*********************************************************************"
      echo -e "***   Check locale/remoto: nessuna azione verra' intrapresa       ***"
      echo -e "*********************************************************************${Z}"
      for curDir in ${myDirs} ; do
         echo -e "${BLU}Controllo la directory ${GREEN}${curDir}${Z}"
         printf "Dir %-20s: Check executing. No sync executed\n" "${curDir}" >> "${log}"
         rclone check "${gdriveName}:${curDir}" "${gdriveBaseDir}/${curDir}" --copy-links 2>&1 | tee "${log}_tmp"
         awk  '{printf" --- %s\n", $0}' "${log}_tmp" >> "${log}"
         rm -f "${log}_tmp"
         echo ""
      done
   ;;
   "loccheck")
      echo -e "${PURPLE}*******************************************************************"
      echo -e "***         Check locale: nessuna azione verra' intrapresa             ***"
      echo -e "**************************************************************************${Z}"
      for curDir in ${myDirs} ; do
         md5file="${md5Dir}/md5sum_${curDir}"
         curMd5=$(find "${gdriveBaseDir}/${curDir}" -exec stat --format="%a %B %D %g %i %n %s %u %y %z" {} \; | tail -n +2 | md5sum)
         if [[ $(cat "${md5file}") != "${curMd5}" ]] ; then
            echo -en "${RED}"
            printf "Dir %-20s: La directory e' stata modificata" "${curDir}"
            echo -e "${Z}"
            printf  "Dir %-20s: Sync check ==>  Directory modificata, $(date)\n" "${curDir}" >> "${log}"
         else
            echo -en "${GREEN}"
            printf "Dir %-20s: La directory NON e' stata modificata" "${curDir}"
            echo -e "${Z}"
            printf "Dir %-20s: Sync check ==> Directory NON modificata, $(date)\n" "${curDir}" >> "${log}"
         fi
      done
   ;;
   "syncnas")
      echo "Sincronizzo il NAS" | tee -a "${log}"
      syncNas
   ;;
   *)
      # Qui non ci si arriva mai, dato che il controllo dei parametri e' fatto
      # tramite la funzione checkParam. Metto il default del case per non avere
      # errori nell'uso di shellcheck
      echo "Questo comando non sara' mai eseguito"
   ;;
esac
echo -e  "Sync terminata: $(date)\n\n " | tee -a "${log}"
