Регламент описывает действия инженера поддержки на этапах сопровождения клиентской миграции Linux-ВМ. Клиент выполняет подготовку ВМ самостоятельно по `0-Документ-клиенту-Linux.md`. Поддержка участвует в двух точках: экспорт образа диска и генерация PreSigned URL.

**В случае нестандартного поведения или сломавшейся ОС** — можно только восстановить ВМ в исходное состояние из резервной копии VMware.

---

## 1. Краткая суть

Клиент запускает toolkit `migration-to-mws` на своей Linux-ВМ под VMware, затем передаёт ВМ в KVM (MWS Cloud Platform). Toolkit решает три задачи: MBR → GPT через `sgdisk`/`parted`, пересборка initramfs с virtio-модулями, установка GRUB2 EFI. Дополнительно — настройка `cloud-init` для работы с metadata MWS.

**Роли в процессе:**

| Стадия | Кто | Что делает |
|---|---|---|
| 1. Подготовка на VMware | Клиент | Запускает `1-run.sh` на исходной ВМ |
| 2. Экспорт в MWS | **Поддержка** | Экспорт OVA, загрузка в S3, PreSigned URL |
| 3. Импорт + первый boot | Клиент | Импорт диска, создание ВМ в MWS |
| 4. Пост-миграция (опц.) | Клиент | Скрипты 5 (cleanup), 6 (cloud-init), 7 (sysprep) |

---

## 2. Где что лежит

### У клиента на VMware

```
migration-to-mws/linux/
├── logs\                                              ← все логи здесь
│   ├── 3-Diagnostic_v4.1_*.log
│   ├── 4-Migration_v4.1_*.log
│   ├── 5-Post-Migration_v4.1_*.log
│   ├── 6-Cloud-Init_v4.1_*.log
│   └── 7-Sysprep_v4.1_*.log
├── configs-cloud-init\
│   ├── 99-mws-datasource.cfg
│   ├── 99-mws-network.cfg
│   └── 99-mws-users.cfg
└── *.sh
```

### На стороне MWS

- **Серийные логи (COM-1, `/dev/ttyS0`)** — неинтерактивный вывод загрузки ВМ. Доступен клиенту в панели MWS Cloud Platform. Содержит вывод UEFI, GRUB, ядра Linux, cloud-init, getty. Буфер 1 МБ, хранится пока ВМ запущена; при выключении очищается.

  Документация: https://mws.ru/docs/cloud-platform/compute/general/serial-port-output.html

- **Консоль MWS Cloud Platform** — состояние ВМ, конфиг, настройки сети и VPC Firewall.

- **VPC Firewall** — правила сетевого доступа к ВМ. Клиент открывает правило под SSH (порт 22) на свой внешний IP (CIDR `/32`) или на `0.0.0.0/0` для диагностики. Без правила SSH-подключение к ВМ не пройдёт.

- **Поддержка MWS Cloud Platform** — используется, если серийных логов недостаточно: можно запросить полный конфиг ВМ, гипервизор-логи, снимок экрана через внутренние механизмы платформы.

---

## 3. Какие логи смотреть в первую очередь

| Проблема | Первый файл | Второй файл |
|---|---|---|
| 4-Migration упал на источнике | `4-Migration_v4.1_*.log` | `3-Diagnostic_v4.1_*.log` |
| ВМ не грузится в KVM | **серийные логи в панели MWS** | `4-Migration_v4.1_*.log` |
| SSH не подключается | `4-Migration_v4.1_*.log` (STEP 2) | настройки VPC Firewall |
| cloud-init не применяет metadata | `6-Cloud-Init_v4.1_*.log` | `/var/log/cloud-init.log` |
| VMware-мусор не удалился | `5-Post-Migration_v4.1_*.log` | `lsmod`, `dpkg -l`/`rpm -qa` |

---

## 4. Структура лога 4-Migration

Лог линейный, читается сверху вниз. Разделён на секции `STEP 0..8`. Пропущенные шаги помечаются `SKIPPED: <причина>` — это норма, а не ошибка.

### STEP 0. PREFLIGHT

**Что проверяет:** права root, версию дистрибутива, семейство (Debian / RHEL), стиль диска, наличие EFI-раздела, LVM, LUKS, свободное место. Также вызывает `Get-LinuxState` (см. §5.0).

**Типичные ошибки:**

```
[Error] Migration blocked: AbortUnknownDistro
```
→ Семейство не Debian-like и не RHEL-like. Toolkit не поддерживает.

```
[Error] Migration blocked: AbortLegacyDistro
```
→ EOL-дистрибутив (CentOS 7, Debian 10, RHEL 7, Ubuntu < 20.04).

```
[Error] Migration blocked: AbortUnsupportedFS
```
→ Корневая ФС не `ext4`/`xfs`/`btrfs`.

```
[Error] Migration blocked: AbortLVM
```
→ Корень на LVM.

```
[Error] Migration blocked: AbortEncrypted
```
→ Корень под LUKS.

```
[Error] Migration blocked: AbortNoPartitionTool
```
→ Нет `sgdisk` и нет `parted`.

```
[Error] Migration blocked: AbortNoInitramfsTool
```
→ Нет `dracut`, `update-initramfs` или `mkinitcpio`.

Полный список блокеров — §5.8.

### STEP 1. FREE SPACE CHECK

Должно быть `Free space: N GB`. Если меньше 2 ГБ — срабатывает блокер `AbortLowSpace`.

### STEP 2. DISABLE SERVICES / TUNING

Останавливает VMware-специфичные службы (`vmtoolsd`, `open-vm-tools`), отключает swap, ставит SELinux в Permissive (временно), останавливает `firewalld`/`ufw`, сбрасывает DNS-кэш.

**Типичные замечания:**

- `Swap: disabled` — норма, временно отключается для миграции.
- `SELinux: Enforcing -> Permissive` — временно, вернётся после reboot.
- `Stopping firewalld` — временно, чтобы cloud-init получил сеть в KVM.

### STEP 3. CONVERT MBR → GPT

Через `Step-ConvertGpt`. Если диск уже GPT — `SKIPPED: disk already GPT`.

**Что должно быть в логе:**

```
[Action]  Backing up MBR partition table to /tmp/mws-mbr-backup.bin
[Action]  Converting to GPT and restoring partition entries
[Success] Disk converted to GPT
```

**Ошибки:**

- `Backup failed` — `sgdisk -b` не смог сохранить таблицу.
- `GPT conversion failed` — `sgdisk -g` упал.
- `Disk is not GPT after conversion` — конвертация прошла, но `blkid`/`parted` не видят GPT. Проверить `partprobe`, `blockdev --rereadpt`.

### STEP 4. ENSURE ESP

Через `Step-CreateESP`. Если ESP уже есть — `SKIPPED: ESP already exists`.

**Что должно быть в логе:**

```
[Action]  Creating ESP (100 MB) at the beginning of the disk
[Success] ESP created
```

**Ошибки:**

- `sgdisk not available` — нет `sgdisk`. Установить.
- `sgdisk failed to create ESP` — смотреть вывод.

### STEP 5. REBUILD INITRAMFS

Через `Step-Initramfs`. Добавляет virtio-модули в конфиг (`/etc/dracut.conf.d/99-mws-virtio.conf` для RHEL или `/etc/initramfs-tools/modules` для Debian) и пересобирает initramfs.

**Что должно быть в логе:**

```
[Action]  Writing /etc/dracut.conf.d/99-mws-virtio.conf
[Action]  Rebuilding initramfs
[Success] initramfs rebuilt with virtio modules
```

**Ошибки:**

- `initramfs rebuild failed` — смотреть `dracut -f` или `update-initramfs -u` вывод.
- `Unknown family for initramfs config` — семейство не распознано, шаг пропускается.

### STEP 6. INSTALL GRUB2 EFI

Через `Step-GrubEfi`. Монтирует ESP как `/mnt/mws-esp`, запускает `grub-install --target=x86_64-efi`, создаёт fallback `\EFI\BOOT\BOOTX64.EFI`.

**Что должно быть в логе:**

```
[Info]    ESP partition: /dev/sda1
[Action]  Running grub-install --target=x86_64-efi
[Action]  Creating fallback bootloader /EFI/BOOT/BOOTX64.EFI
[Success] GRUB2 EFI installed
```

**Ошибки:**

- `grub-install not found` — нет пакета GRUB2 EFI. Toolkit пытается установить автоматически.
- `No ESP partition` — предыдущий шаг `Step-CreateESP` упал. См. §5.4.
- `Cannot locate ESP partition` — `lsblk` не находит раздел с типом `c12a7328-...`.
- `grub-install returned non-zero` — смотреть вывод.

### STEP 7. VERIFY BOOT

Через `Step-VerifyBoot`. Проверяет GPT, ESP, fallback bootloader, GRUB EFI directory, initramfs.

**Что должно быть в логе:**

```
[Success]  [+] Disk style: GPT
[Success]  [+] ESP partition present
[Success]  [+] Fallback /EFI/BOOT/BOOTX64.EFI present
[Success]  [+] GRUB EFI directory present
[Success]  [+] initramfs present
[Info]     Boot verification: 5 OK, 0 issue(s)
```

Если есть `[!]` — разбирать соответствующую строку.

### STEP 8. CLEANUP & SHUTDOWN

```
[Success] PREPARATION COMPLETED SUCCESSFULLY (v4.1)
```

Если строки нет — искать `[Error]` в конце лога.

---

## 5. Диагностика

### 5.0. Get-LinuxState — что показывает

Перед началом миграции оба скрипта — `2-Orchestrator.sh` и `3-Diagnostic.sh` — вызывают функцию `Get-LinuxState`. Она собирает объект состояния:

```
DISTRO_PRETTY_NAME     Debian 12 (bookworm) / Rocky Linux 8.7 / ...
DISTRO_FAMILY          debian | rhel | unknown
DISTRO_SUPPORTED       yes | no | eol
INIT_SYSTEM            systemd | openrc | sysvinit
BOOTLOADER             grub2-efi | grub2-bios | systemd-boot | unknown-efi | unknown-bios
HAS_UEFI_BOOT          yes | no
PKG_MANAGER            apt | dnf | yum | zypper | pacman | apk | unknown
ENVIRONMENT            VMware | KVM | Hyper-V | Xen | BareMetal | Unknown
SYS_DISK               /dev/sda / /dev/vda / ...
DISK_STYLE             mbr | gpt | unknown
ROOT_FSTYPE            ext4 | xfs | btrfs | ...
ROOT_RW                yes | no | unknown
HAS_EFI                yes | no
HAS_LVM                yes | no
HAS_LUKS               yes | no
FREE_SPACE_GB          число
CLOUD_INIT_READY       yes | no
VIRTIO_IN_INITRAMFS    yes | maybe | no
HAS_PARTITION_TOOL     yes | no
HAS_INITRAMFS_TOOL     yes | no
BLOCKER                пусто или код блокера (см. §5.8)
```

**Как читать:**

- Если `BLOCKER` не пуст — миграция не запустится. См. §5.8.
- Оркестратор принимает решение на основе комбинации полей: `DISK_STYLE + HAS_EFI + BOOTLOADER`. Если `gpt` + `yes` + `grub2-efi` — состояние «Ready for export». Иначе — «Migration needed».

**Где смотреть в логе:** §0 STATE SUMMARY в начале `3-Diagnostic_v4.1_*.log`, а также вывод оркестратора в консоли до запуска скриптов.

### 5.1. Дерево диагностики

```
ВМ загрузилась в KVM?
├── НЕТ
│   ├── Серийные логи (панель MWS) показывают:
│   │   ├── Пусто → см. §5.4 (ESP или firmware)
│   │   ├── GRUB работает, но ядро падает → см. §5.2 (initramfs)
│   │   └── GRUB rescue → см. §5.4 (GRUB или ESP)
│   └── Серийные логи не помогают → обратиться в поддержку MWS
│
└── ДА
    ├── SSH работает?
    │   ├── НЕТ → см. §5.3 (VPC Firewall, sshd)
    │   └── ДА
    │       ├── cloud-init применил metadata?
    │       │   ├── НЕТ → см. §5.5 (cloud-init)
    │       │   └── ДА
    │       │       ├── VMware-мусор в системе → см. §5.6
    │       │       └── Всё OK → готово
```

### 5.2. ВМ не грузится в KVM — разбор серийных логов

**Симптом:** ВМ не загружается. GRUB не появляется, ядро падает, система уходит в kernel panic.

**Шаг 1. Открыть серийные логи в панели MWS.**

В панели MWS Cloud Platform → ВМ → вкладка «Серийные логи». Буфер содержит вывод UEFI, GRUB, ядра, cloud-init, getty. Буфер 1 МБ, хранится пока ВМ запущена; при выключении очищается.

**Интерпретация:**

| Что видно в конце лога | Что значит |
|---|---|
| Пусто, ни одной строки | UEFI не запускает GRUB. Проверить ESP и fallback `/EFI/BOOT/BOOTX64.EFI`. |
| GRUB-меню или строка «Booting ...» | GRUB работает. Проблема в ядре или initramfs. |
| «Kernel panic — not syncing» | Ядро загрузилось, но не смонтировало корень. Скорее всего `virtio_scsi` не в initramfs. |
| «dracut-initqueue timeout» | То же самое: `virtio_scsi` не найден в initramfs. |
| «grub rescue>» | GRUB запустился, но не нашёл `grub.cfg` или раздел `/boot`. |
| Ядро загрузилось, видны строки systemd, но система зависла | Проблема на уровне systemd или драйверов. |
| Видны строки cloud-init, потом ошибка | Проблема в metadata или network-config. Смотреть `/var/log/cloud-init.log` на диске. |

**Шаг 2. Если логи не показывают причину — обратиться в поддержку MWS Cloud Platform.**

Клиент не может интерактивно зайти в консоль ВМ (QEMU/VNC недоступны), но серийные логи дают представление о стадии сбоя. Приложить:

- снимок серийных логов;
- лог `4-Migration_v4.1_*.log`;
- текущий конфиг ВМ (machine type, firmware, disk controller).

Поддержка MWS может предоставить:

- полный конфиг ВМ;
- гипервизор-логи;
- снимок экрана через внутренние механизмы.

**Шаг 3. Проверить конфиг по чек-листу.**

- Machine type = **q35**
- Firmware = **UEFI**
- Secure Boot = **OFF**
- Диск = **VirtIO SCSI** (не SATA, не IDE)
- Network = **VirtIO**

Если конфиг отличается — пересоздать ВМ.

Если конфиг правильный и серийные логи показывают, что загрузка доходит до initramfs, но падает — вернуться к §5.4 (initramfs или GRUB).

### 5.3. SSH не подключается после первого boot в KVM

**Симптом:** ВМ загрузилась, есть внешний IP, но SSH не подключается.

**Проверки на стороне MWS (без доступа в ВМ):**

1. **VPC Firewall.** В свойствах ВМ на вкладке «Сетевые интерфейсы» должно быть правило для SSH (порт 22). В правиле указан текущий внешний IP клиента (CIDR `/32`) или `0.0.0.0/0`. Если IP клиента изменился — правило не сработает.

   Документация: https://mws.ru/docs/cloud-platform/vpc/general/vpc-firewall-overview.html

2. **Внешний IPv4.** В свойствах ВМ на вкладке «Сетевые интерфейсы» должна быть строка «Внешний IPv4». Если её нет — oneToOneNat не привязан.

3. **Серийные логи.** Открыть серийные логи, проверить, что система загрузилась и sshd стартовал. Обычно в serial-логе видны строки systemd о запуске сервисов.

**Проверки внутри ВМ — если SSH всё-таки подключился:**

4. **sshd запущен.**

   ```bash
   systemctl status sshd     # RHEL-family
   systemctl status ssh      # Debian-family
   ```

5. **Правило firewall внутри ВМ.**

   ```bash
   # firewalld
   firewall-cmd --list-all
   # ufw
   ufw status
   ```

   Порт 22 должен быть разрешён.

Если SSH не подключается ни по одному варианту — обратиться в поддержку MWS Cloud Platform. Клиент не может сам зайти в консоль ВМ, но серийные логи дают представление о стадии.

### 5.4. 4-Migration упал на STEP: Install GRUB2 EFI

**Симптом:** `[Error] GRUB2 EFI installation failed` или `[Error] Cannot locate ESP partition`. В серийных логах при загрузке — пусто или `grub rescue>`.

**Причины:**

- ESP-раздел не был создан на предыдущем шаге (`Step-CreateESP` упал).
- `grub-install` не установлен и не устанавливается.
- Проблемы с монтированием ESP.

**Что делать:**

1. Смотреть лог до STEP: Install GRUB2 EFI. Если перед ним был SKIP или Error на `Step-CreateESP` — сначала разобраться с ESP.

2. Проверить наличие ESP:

   ```bash
   lsblk -no NAME,PARTTYPE /dev/sda | grep c12a7328
   ```

3. Если ESP есть, но `grub-install` не находит — проверить модули GRUB для EFI:

   ```bash
   # Debian-family
   apt install grub-efi-amd64
   # RHEL-family
   dnf install grub2-efi-x64
   ```

4. Если ESP нет и не создаётся автоматически — ручное создание:

   ```bash
   sgdisk -n 0:0:+100M -t 0:ef00 -c 0:"EFI System Partition" /dev/sda
   ```

5. После ручной правки — запустить `4-Migration.sh` повторно. Скрипт идемпотентен.

### 5.5. cloud-init не применяет metadata

**Симптом:** ВМ загрузилась, SSH работает, но hostname не изменился, сеть не настроена, пользователь из metadata не создан.

**Причины:**

1. **cloud-init не установлен.** Проверить: `command -v cloud-init`. Если нет — запустить `6-Cloud-Init.sh`.

2. **Конфиги не разложены.** Проверить: `ls /etc/cloud/cloud.cfg.d/99-mws-*`. Должны быть три файла.

3. **Datasource не находит config-drive.** Смотреть `/var/log/cloud-init.log`:

   ```bash
   grep -i "configdrive\|noCloud\|datasource" /var/log/cloud-init.log
   ```

   Если datasource не найден — проверить, что MWS аттачит config-drive к ВМ. Через поддержку MWS.

4. **cloud-init уже отработал раньше.** После первого boot файл-маркер `/var/lib/cloud/instance/boot-finished` не даёт повторно применить metadata. Проверить:

   ```bash
   cloud-init status
   ```

   Если `done` — это норма. Если нужно повторить — `cloud-init clean --logs`, затем reboot.

5. **Синтаксис конфига битый.** Проверить:

   ```bash
   cloud-init schema --config-file /etc/cloud/cloud.cfg.d/99-mws-datasource.cfg
   ```

### 5.6. VMware-мусор не удаляется

**Симптом A:** после `5-Post-Migration.sh` пакет `open-vm-tools` всё ещё в системе.

**Причины:** служба держит файлы, нужно остановить перед удалением.

**Что делать:**

```bash
# Остановить службу
systemctl stop vmtoolsd 2>/dev/null
systemctl disable vmtoolsd 2>/dev/null

# Удалить пакет
# Debian-family
apt remove -y open-vm-tools
# RHEL-family
dnf remove -y open-vm-tools
```

Если не помогает — перезагрузиться и запустить `5-Post-Migration.sh` ещё раз.

**Симптом B:** VMware-модули ядра всё ещё загружены.

**Что делать:**

```bash
lsmod | grep -E "^vmw_|^vmxnet|^vmhgfs|^vsock"
rmmod <module_name>
```

Если модуль не выгружается — он используется. Перезагрузка.

**Симптом C:** udev persistent net rules или MACAddress в `.link` файлах.

**Что делать:** запустить `5-Post-Migration.sh` повторно после reboot.

### 5.7. initramfs пересобирается с ошибками

**Симптом:** `[Error] initramfs rebuild failed`. В серийных логах при загрузке — `Kernel panic` или `dracut-initqueue timeout`.

**Что делать:**

**Debian-family:**

```bash
update-initramfs -u -k all 2>&1 | tail -50
```

Часто проблема — не хватает модуля или конфликт с `/etc/initramfs-tools/modules`.

**RHEL-family:**

```bash
dracut -f --regenerate-all 2>&1 | tail -50
```

Часто проблема — не хватает `dracut-config-generic` или `dracut-network` для full initramfs.

**Проверить модули в итоговом initramfs:**

```bash
lsinitrd /boot/initramfs-$(uname -r).img | grep virtio    # RHEL
lsinitramfs /boot/initrd.img-$(uname -r) | grep virtio    # Debian
```

Должны быть `virtio_pci`, `virtio_scsi`, `virtio_blk`.

### 5.8. Блокеры

Блокеры — состояния, при которых `4-Migration.sh` не запускает трансформацию. Оркестратор их показывает, скрипт падает с `Migration blocked: <код>`.

Список: `AbortUnknownDistro`, `AbortLegacyDistro`, `AbortNoDisk`, `AbortUnsupportedFS`, `AbortLVM`, `AbortEncrypted`, `AbortLowSpace`, `AbortNoEFI`, `AbortNoPartitionTool`, `AbortNoInitramfsTool`.

| Блокер | Что значит | Что делать |
|---|---|---|
| `AbortUnknownDistro` | Семейство не Debian-like и не RHEL-like | Обновить дистрибутив или перенести вручную |
| `AbortLegacyDistro` | EOL: CentOS 7, Debian 10, RHEL 7, Ubuntu < 20.04 | Обновить дистрибутив или чистая установка в KVM |
| `AbortNoDisk` | Не определили системный диск | Проверить `lsblk`, `findmnt /` |
| `AbortUnsupportedFS` | Корень не `ext4`/`xfs`/`btrfs` | Сконвертировать или мигрировать вручную |
| `AbortLVM` | Корень на LVM | LVM требует ручной подготовки |
| `AbortEncrypted` | Корень под LUKS | Расшифровать: `cryptsetup luksClose` |
| `AbortLowSpace` | Свободно < 2 ГБ | Освободить минимум 2 ГБ |
| `AbortNoEFI` | GPT без ESP-раздела | Разметка повреждена, восстановить из бэкапа |
| `AbortNoPartitionTool` | Нет `sgdisk` и `parted` | `apt install gdisk` / `dnf install gdisk` |
| `AbortNoInitramfsTool` | Нет `dracut`, `update-initramfs`, `mkinitcpio` | `apt install initramfs-tools` / `dnf install dracut` |

Все блокеры требуют вмешательства на клиентской стороне. Поддержка может помочь с диагностикой, но исправление — за клиентом.

---

## 6. Что просить у клиента

```
Пожалуйста, пришлите:

1. Все логи из папки migration-to-mws/linux/logs/
   (лучше архивом)

2. Серийные логи из панели MWS Cloud Platform (вкладка «Серийные
   логи»), если ВМ не загружается — снимок или текстовый экспорт.

3. Что делали:
   - Какой Linux-дистрибутив мигрируется (Debian 11/12, Ubuntu 22.04/24.04,
     Rocky 8, Alma 8, Oracle 8, Fedora 35+)
   - На какой стадии остановилось:
     [ ] Стадия 1 (4-Migration на источнике)
     [ ] Стадия 2 (экспорт - делает поддержка)
     [ ] Стадия 3 (импорт + создание ВМ + первый boot)
     [ ] Стадия 4 (пост-миграция)

4. Запускались ли пост-миграционные скрипты:
   [ ] 5-Post-Migration.sh
   [ ] 6-Cloud-Init.sh
   [ ] 7-Sysprep.sh

5. Если ВМ загрузилась в KVM (у клиента есть SSH-доступ), вывод команд:
   lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
   lsmod | grep virtio
   cloud-init status
   systemctl --failed

   Если ВМ НЕ загрузилась — этот пункт пропустить. Ограничиться
   логами + серийными логами.
```

---

## 7. Технический раздел: почему это работает

### Загрузка Linux в KVM

1. **EDK II firmware** (UEFI) сканирует GPT, находит ESP-раздел по типу `c12a7328-...`.
2. **Загружает `\EFI\BOOT\BOOTX64.EFI`** или `\EFI\<distro>\grubx64.efi` (в зависимости от того, что первым найдёт).
3. **GRUB2** читает `grub.cfg`, находит ядро и initramfs.
4. **Ядро** монтирует initramfs, оттуда загружает `virtio_pci`, `virtio_scsi`, `virtio_blk`.
5. **Монтирует корень** на virtio-диске, запускает `systemd` (или другой init).
6. **cloud-init** читает metadata, применяет настройки.

### Точки разрыва VMware ↔ KVM для Linux

1. **Disk controller:** VMware использует `pvscsi` или `lsilogic`, KVM — `virtio-scsi`. Драйверы переключаются автоматически, потому что virtio уже в ядре. Но initramfs должен содержать `virtio_scsi` и `virtio_blk`, иначе корень не смонтируется.
2. **Bootloader:** VMware может грузить `grub2-bios` из MBR, KVM требует `grub2-efi` из ESP. Требуется установка GRUB2 EFI.
3. **Disk layout:** VMware может использовать MBR, KVM ожидает GPT. Требуется конвертация.
4. **Network:** VMware использует `vmxnet3`, KVM — `virtio-net`. Драйверы в ядре, но udev persistent rules могут привязывать старые имена/MAC к интерфейсам.
5. **Metadata:** VMware не передаёт metadata в гостя. MWS аттачит config-drive, который читает `cloud-init`. Требуется установка cloud-init.

### Почему LVM и LUKS — блокеры

- **LVM.** Корень на логическом томе `vg/lv`. При конвертации MBR→GPT через `sgdisk -g -l backup`, таблица разделов сохраняется, но LVM-метаданные могут оказаться не в том месте. Автоматическая миграция не гарантирована.
- **LUKS.** Корень на зашифрованном томе. `initramfs` должен уметь расшифровать том на этапе загрузки, что требует `cryptsetup` в initramfs. Кроме того, `sgdisk` может повредить LUKS-заголовок при конвертации.

Оба сценария требуют ручной подготовки и не покрываются toolkit.

### Почему `virt-sysprep` не используется изнутри ВМ

`virt-sysprep` работает с **офлайн-диском** через `libguestfs`. То есть система, которую мы хотим «отвязать», должна быть выключена, а её диск — смонтирован как образ. Изнутри работающей ВМ это невозможно.

Аналог для случая «мы внутри системы» — `cloud-init clean --logs --seed`. Он сбрасывает состояние cloud-init, удаляет SSH host keys, machine-id, bash history. Этого достаточно для подготовки к клонированию.

Если клиент хочет именно `virt-sysprep`, это делается с хоста KVM/MWS, не изнутри ВМ.

---

## 8. Диагностические команды

> Все команды ниже выполняются внутри работающей ВМ через SSH. Если SSH не работает и ВМ недоступна — команды выполнить нельзя. Единственный путь в этом случае — серийные логи в панели MWS и обращение в поддержку.

```bash
# Диск и разделы
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,PARTTYPE
parted -s /dev/sda print
blkid
findmnt

# EFI
ls -la /boot/efi/EFI/
ls -la /boot/efi/EFI/BOOT/
ls -la /boot/efi/EFI/mws/ 2>/dev/null
efibootmgr -v

# Bootloader
grub-install --version 2>/dev/null || grub2-install --version
ls -la /boot/grub/grub.cfg /boot/grub2/grub.cfg 2>/dev/null

# initramfs
ls -la /boot/initramfs-*.img /boot/initrd.img-* 2>/dev/null
lsinitrd /boot/initramfs-$(uname -r).img 2>/dev/null | grep virtio
lsinitramfs /boot/initrd.img-$(uname -r) 2>/dev/null | grep virtio

# virtio в ядре
lsmod | grep virtio
dmesg | grep -i virtio

# cloud-init
cloud-init --version
cloud-init status
ls /etc/cloud/cloud.cfg.d/99-mws-*
cat /var/log/cloud-init.log | tail -50

# VMware-мусор
lsmod | grep -E "^vmw_|^vmxnet|^vmhgfs|^vsock"
dpkg -l 2>/dev/null | grep -i vmware
rpm -qa 2>/dev/null | grep -i vmware
ls -la /etc/udev/rules.d/70-persistent-net.rules 2>/dev/null
grep -r "^MACAddress=" /etc/systemd/network/ 2>/dev/null

# Сеть
ip -br addr
ip route
cat /etc/resolv.conf
systemctl is-active NetworkManager sshd 2>/dev/null
systemctl is-active systemd-networkd ssh 2>/dev/null
```

---

## 9. Эскалация

Если после всех шагов проблема не решена — эскалировать на команду разработки toolkit. Приложить:

1. Все логи из `logs/`.
2. Серийные логи из серийной консоли MWS Cloud Platform
3. Вывод диагностических команд из §8 (если ВМ загрузилась).
4. Данные от поддержки MWS Cloud Platform: конфиг ВМ, гипервизор-логи.
5. QEMU-конфиг ВМ (machine type, firmware, disk controller, network).
6. Настройки VPC Firewall для этой ВМ.