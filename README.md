# Kit RAID offline per Ubuntu 24.04

Kit per creare un array **mdadm** su un server **Ubuntu 24.04 LTS (noble) amd64** che **non ha internet**. I pacchetti sono già nel repository: lo script non scarica nulla.

Lo scenario per cui è stato preparato: **7 dischi da circa 7 TB**, **RAID6**, **5 dischi attivi + 2 hot spare**. Capacità utile circa `(5 - 2) x 7 TB = 21 TB`. Lo stesso script chiede il livello e può creare anche gli altri RAID che mdadm usa per i dati: **RAID0, RAID1, RAID4, RAID5, RAID6, RAID10**. **linear** solo se il kernel ha il modulo: sul kernel 6.8 di Ubuntu 24.04 non c'è.

La guida con gli screenshot della sessione SSH e i pulsanti **Copia** (testo pulito, senza gli a-capo di Windows) è `docs/guida-raid.html`. Aprila sul portatile prima di staccare la rete. Sul server, da terminale, basta questo README.

## Installazione rapida dal file .tar.gz

Nella pagina principale del repository c'è **`raid6-kit-ubuntu-24.04-amd64.tar.gz`** (40 MB): contiene la cartella `raid6-kit` completa, script e 81 pacchetti `.deb`. Scaricalo (pulsante *Download raw file*) e copialo sulla chiavetta.

SHA-256: `c7d739e2cc988b82bd1fd8d8fee7b658fb842e430aac338d843f817fb9d9f277`

Sul server, senza rete (adatta il percorso della chiavetta):

```bash
sha256sum /media/$USER/CHIAVETTA/raid6-kit-ubuntu-24.04-amd64.tar.gz
sudo tar -xzf /media/$USER/CHIAVETTA/raid6-kit-ubuntu-24.04-amd64.tar.gz -C /opt
cd /opt/raid6-kit
sudo RAID6_PLAN_ONLY=1 bash scripts/setup-raid6.sh
sudo bash scripts/setup-raid6.sh
```

Lo scompattamento crea `/opt/raid6-kit`. Il manuale con gli screenshot non è nel `.tar.gz`: è `docs/guida-raid-tutto-in-uno.html`, da aprire sul portatile.

## Cosa c'è nel repository

| Percorso | A cosa serve |
| --- | --- |
| `raid6-kit-ubuntu-24.04-amd64.tar.gz` | La cartella `raid6-kit` in un solo file, da scompattare in `/opt` |
| `raid6-kit/packages/` | 81 pacchetti `.deb` di Ubuntu 24.04 noble amd64 e l'elenco `MANIFEST.txt` |
| `raid6-kit/scripts/setup-raid6.sh` | Script interattivo. Il nome è rimasto quello storico: dentro chiede il livello |
| `raid6-kit/LEGGIMI.txt` | Promemoria corto da leggere sulla chiavetta |
| `docs/guida-raid.html` | Manuale offline con la sessione SSH, passo per passo, e copia in un clic |
| `tools/fetch-ubuntu-debs.py` | Rigenera i `.deb` da una macchina **con** internet. Sul server spento non serve |

`multipath` e `faulty` non sono nel menu. Il primo non è un RAID di dischi diversi. Il secondo serve solo a simulare settori rotti.

## Copia sulla chiavetta

Da un PC con il repository:

```bash
cp -a raid6-kit docs /media/$USER/CHIAVETTA/
```

Sul server, senza rete:

```bash
sudo mkdir -p /opt
sudo cp -a /media/$USER/CHIAVETTA/raid6-kit /opt/raid6-kit
cd /opt/raid6-kit
```

Controlla di essere sul sistema giusto:

```bash
dpkg --print-architecture
. /etc/os-release && echo "$VERSION_CODENAME $VERSION_ID"
```

Deve stampare `amd64` e `noble` / `24.04`.

Anteprima dei pacchetti, senza toccare i dischi:

```bash
sudo RAID6_PLAN_ONLY=1 bash scripts/setup-raid6.sh
```

Poi, quando `lsblk` ti convince:

```bash
sudo bash scripts/setup-raid6.sh
```

## Cosa ti chiede, in ordine

Invio accetta il valore tra parentesi. Per distruggere i dischi devi scrivere `YES` in maiuscolo. Qualsiasi altra risposta annulla.

1. Livello: `0`, `1`, `4`, `5`, `6`, `10`. Default **6**. Accetta anche `raid6`, `stripe`, `mirror`. `linear` compare solo se il kernel carica il modulo `linear`. Sul kernel 6.8 di Ubuntu 24.04 (quello GA) il modulo non c'è: è stato tolto e rimesso dal kernel 6.12. Lo script lo dice e non tocca i dischi.
2. Solo per RAID10, il layout: `n2` (default), `f2`, `o2`, oppure più copie (`n3`...) se i dischi bastano.
3. Quanti dischi attivi. Con 7 o più dischi e RAID6 il default è **5**.
4. Quanti hot spare, solo se il livello li usa. È un numero solo: `0`, `1`, `2`. Invio vale **0**, tranne RAID6 con almeno 7 dischi, dove vale **2**. RAID0 e linear non lo chiedono: uno spare non ricostruisce un disco. La riga `1 2 3` arriva dopo, non qui.
5. I numeri dei dischi attivi, separati da spazio, per esempio `1 2 3 4 5`.
6. I numeri degli spare, se ne hai chiesti. Non possono coincidere con gli attivi.
7. Punto di mount. Default `/mnt/raid6` per il RAID6, `/mnt/raid0` per il RAID0, `/mnt/linear` per linear.
8. Nome dell'array, massimo 32 caratteri. Default `raid6data`, `raid0data`, `lineardata`.
9. `YES` per partizionare e creare l'array.
10. Se `/dev/md0` esiste già, un secondo `YES` per fermarlo e rifarlo.
11. Filesystem: `xfs` (default) oppure `ext4`.

Prima del `YES` lo script ristampa il riepilogo: device, livello, chunk, bitmap, dischi con la dimensione, mount. Se un disco scelto è sotto 1 TB avvisa: i dischi previsti sono da circa 7 TB, ed è facile includere la chiavetta per sbaglio.

I dischi di sistema, quelli montati e lo swap non compaiono nella lista. Controlla comunque con:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
```

## Come lo fa

Tutto resta sulla macchina. Nessun `apt update`, nessun download.

1. **Architettura.** Si ferma se `dpkg --print-architecture` non è `amd64`. Su un Ubuntu diverso da 24.04 chiede conferma.
2. **Pacchetti.** Legge i `.deb` in `packages/` e installa solo ciò che manca per far funzionare `mdadm`, `parted`, `gdisk`, `xfsprogs`, `e2fsprogs`, più `finalrd` e `kmod` se non ci sono, più le dipendenze di quei pacchetti che sul sistema non ci sono. Non aggiorna il resto del sistema. Non tocca `libc6`, `systemd` e `udev` se la versione già installata basta; se non basta, si ferma **prima** di scrivere sui dischi. `dpkg` gira in modalità non interattiva (`--force-confdef --force-confold`), così non ti ruba le risposte dei prompt. Le domande di `debconf` di mdadm prendono i default: controllo mensile acceso, mail a `root`.
3. **Dischi.** `lsblk` elenca solo dischi interi il cui nome è `sd*`, `hd*`, `vd*`, `xvd*`, `nvme*n*`, `mmcblk*` o `loop*`. Salta il disco di root, qualsiasi disco con un filesystem montato e lo swap. `zram` e i device `dm-*` non vengono proposti.
4. **Livello.** Il minimo di mdadm è applicato prima di farti scegliere i numeri: linear, RAID0, RAID1 e RAID10 almeno 2, RAID4 e RAID5 almeno 3, RAID6 almeno 4. Per il layout RAID10 `n3` il minimo diventa 3, e così via.
5. **Partizioni.** Se un disco scelto è ancora agganciato a un array (anche `md127` riassemblato da solo al boot), lo ferma. Cancella le firme (`wipefs`) e il superblocco **prima** di scrivere la tabella: azzerare il disco dopo aver creato la GPT la distruggerebbe e la partizione sparirebbe. Poi scrive una GPT nuova e una sola partizione che parte a **1 MiB** e arriva in fondo. Il tipo è `FD00`, Linux RAID. Aspetta che compaia `/dev/sda1` oppure `/dev/nvme0n1p1` (fino a qualche secondo): non si fida del primo controllo. Poi cancella anche le firme sulla partizione, così mdadm non si ferma su un superblocco vecchio. Se `wipefs` non riesce, esce: non va avanti con un disco occupato.
6. **Array.** Il comando è `mdadm --create` con metadata **1.2** e `--run`, perché il `YES` che hai già dato è la conferma: mdadm non deve fare una seconda domanda e mangiarsi la risposta del filesystem. Le opzioni dipendono dal livello:
   - RAID0: `--chunk=512` (KiB), niente bitmap, niente spare. Nessuna ridondanza.
   - RAID1: bitmap interna, chunk non usato, spare ammessi.
   - RAID4 e RAID5: chunk 512 KiB, bitmap interna, spare ammessi. Un disco di parità.
   - RAID6: chunk 512 KiB, bitmap interna, spare ammessi. Due dischi di parità.
   - RAID10: come sopra, più `--layout` (`n2`, `f2`, `o2`, ...).
   - linear: né chunk né bitmap né spare. Mette i dischi uno dopo l'altro.
   Il chunk si cambia solo esportando `CHUNK_KIB` prima dello script (tra 4 e 65536). Il device di default è `/dev/md0`; per usarne un altro esporta `MD_DEVICE`.
7. **Filesystem.** `mkfs.xfs -f` oppure `mkfs.ext4 -F`. Dove lo stripe esiste, allinea il filesystem al chunk:
   - RAID0: tanti stripe quanti sono i dischi
   - RAID4 e RAID5: dischi meno 1
   - RAID6: dischi meno 2
   - RAID10: dischi divisi per il numero di copie, se la divisione è intera
   RAID1 e linear non hanno stripe, quindi il mkfs è normale. Se l'allineamento fallisce, riprova il mkfs senza quelle opzioni.
8. **Persistenza.** Aggiunge in `/etc/mdadm/mdadm.conf` la riga `ARRAY` di questo array (sostituisce una riga vecchia dello stesso device, dello stesso nome o dello stesso UUID, e lascia gli altri array). Lancia `update-initramfs -u` se c'è. In `/etc/fstab` scrive l'UUID del filesystem, non il nome `/dev/md0`, con `defaults,nofail,x-systemd.device-timeout=120`: se l'array al boot non sale entro 120 secondi, il server parte lo stesso.

La sync iniziale di un RAID5/6 da 7 TB può durare **ore o giorni**. Il volume si monta subito e si può usare, con le prestazioni ridotte finché `/proc/mdstat` non arriva a fine corsa. Un RAID0 o un linear non ricostruiscono: o sono su subito, o i dati non c'erano.

## Se lo rilanci

I dischi di un array ancora montato non compaiono nella lista. Per rifarlo sugli stessi dischi:

```bash
sudo umount /mnt/raid6
sudo mdadm --stop /dev/md0
sudo bash scripts/setup-raid6.sh
```

Lo script chiede un secondo `YES` prima di fermare `/dev/md0`, se esiste ancora.

## Dopo

```bash
cat /proc/mdstat
sudo mdadm --detail /dev/md0
findmnt /mnt/raid6
df -hT /mnt/raid6
```

Se hai scelto un altro livello, il mount è quello che hai confermato nel riepilogo (`/mnt/raid5`, `/mnt/raid10`, `/mnt/linear`, ...).

Al riavvio l'array deve tornare da solo. Se non torna:

```bash
sudo mdadm --assemble --scan
sudo mount -a
```

## Cosa non fa

- Non scarica pacchetti e non lancia `apt update`.
- Non aggiorna libc, systemd o il kernel.
- Non mette in RAID il disco di sistema e non tocca uno swap attivo.
- Non crea `multipath` né `faulty`.
- Non chiede un secondo `YES` a mdadm: se il riepilogo è giusto, il `YES` finale basta.
- Non aspetta la fine della resync.

## Se si ferma

Lo script esce prima di scrivere sulle partizioni se manca un pacchetto o se un `.deb` è illeggibile. Se si ferma **dopo** il `YES`, i dischi scelti possono essere già stati azzerati: non rilanciarlo alla cieca su altri dischi. Leggi le ultime righe, poi `lsblk` e `cat /proc/mdstat`.

Un messaggio `update-initramfs non riuscito` non cancella l'array: è già montato. Resta da capire il boot, con i comandi della sezione precedente.
