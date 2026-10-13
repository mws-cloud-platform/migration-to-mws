Пошаговая инструкция для миграции Linux-ВМ из VMware в KVM (MWS Cloud Platform)

---

## Требования

- Один из поддерживаемых дистрибутивов:
  - **Debian-like:** Debian 11+, Ubuntu 20.04+, Mint 21+
  - **RHEL-like:** RHEL 8+, Rocky 8+, AlmaLinux 8+, Fedora 35+, Oracle Linux 8+
- Права root (или `sudo`).
- 2 ГБ свободно на корневом разделе.
- Интернет или установленные пакеты `cloud-init`, `gdisk`/`parted`, `dracut`/`initramfs-tools`.

Не поддерживается\не тестировались: CentOS 6/7, RHEL 6/7, Debian 10 (EOL), Alpine, Arch, openSUSE, SLES, FreeBSD. Для них предпочтительна чистая установка в KVM.


---

## Структура пакета

```
linux/
├── 1-run.sh                  ← точка входа
├── 2-Orchestrator.sh         ← определяет состояние, запускает нужное
├── 3-Diagnostic.sh           ← диагностика (read-only)
├── 4-Migration.sh            ← трансформация
├── 5-Post-Migration.sh       ← чистка VMware-мусора (запуск в KVM)
├── 6-Cloud-Init.sh           ← установка и настройка cloud-init
├── 7-Sysprep.sh              ← опционально: golden image
├── lib-core.sh               ← ядро: log, detect, handlers
├── lib-steps-boot.sh         ← шаги загрузки: GPT, initramfs, GRUB
├── lib-steps-runtime.sh      ← шаги runtime: cloud-init, cleanup
├── configs-cloud-init\       ← конфиги cloud-init
└── logs\                     ← создаётся при запуске
```

---

## Что делает toolkit

На исходной Linux-ВМ:

- Проверяет совместимость: дистрибутив, стиль диска, наличие EFI-раздела, LVM/LUKS, свободное место.
- Конвертирует MBR в GPT.
- Создаёт ESP-раздел, если его нет.
- Пересобирает initramfs с модулями `virtio_scsi`, `virtio_blk`, `virtio_net`.
- Устанавливает GRUB2 EFI загрузчик.
- Настраивает `cloud-init` под работу с metadata MWS.
- Снимает `open-vm-tools`.

Меньше шагов, чем в Windows: драйверы VirtIO уже в ядре, реестра нет, boot-critical регистрация сводится к пересборке initramfs.

Что не делает: не меняет данные, не переустанавливает приложения, не обновляет дистрибутив.

---

## Порядок работы

### Этап 1. На исходной ВМ (VMware)

1. Скопируйте папку `migration-to-mws/linux/` на рабочий стол ВМ.
2. Убедитесь, что нужные пакеты доступны (либо в системе, либо через интернет): `cloud-init`, `gdisk` (или `parted`), `dracut` (или `initramfs-tools`).
3. Запустите `1-run.sh` от root:

```bash
sudo ./1-run.sh
```

Скрипт сам определит семейство (Debian или RHEL) и применит нужные обработчики.

4. Дождитесь выключения ВМ. Перед выключением будет пауза `Press Enter to shutdown` — можно забрать логи из `logs/`.

В логе `4-Migration_v4.1_*.log` проверьте:

```
PREPARATION COMPLETED SUCCESSFULLY (v4.1)
```

И выше по тексту — критично важные строки:

```
STEP: Convert MBR to GPT
STEP: Ensure EFI System Partition
STEP: Rebuild initramfs with virtio modules
STEP: Install GRUB2 EFI
```

Если строки есть — переходите к этапу 2. Если `ERROR` — приложите лог в поддержку.

### Этап 2. Экспорт и передача в MWS

ВМ выключена. Экспортируйте её штатным способом (своими руками или через поддержку вашего облака), загрузите диск в S3 и получите Path-Style PreSigned URL для импорта в MWS Cloud Platform.

Рекомендуемые форматы, ограничения и команды конвертации — в README на GitHub.

### Этап 3. Импорт в MWS

1. **Compute → Образы → Создать → Образ по ссылке.** Вставьте Path-Style PreSigned URL, укажите тип ОС = Linux, размер диска — как минимум как в исходной ВМ.

2. **Compute → ВМ → Создать из образа.** Задайте vCPU, RAM, зону размещения, зарезервируйте внешний IP (`oneToOneNat`).

3. **Откройте правило файрвола для SSH (порт 22)** на доступ с вашего внешнего IP или через `0.0.0.0/0` для теста. Узнать свой внешний IP: https://ifconfig.me

4. Запустите ВМ.

5. Подключитесь по SSH, используя старый логин и пароль (или публичный ключ) от исходной ВМ. Первый boot занимает около 5 минут: cloud-init читает metadata и применяет настройки.

### Этап 4. Пост-настройка (опционально)

Внутри работающей ВМ в KVM:

- `5-Post-Migration.sh` — удаление `open-vm-tools`, чистка следов VMware, удаление устаревших udev-правил и MAC-адресов из network .link-файлов.
- `6-Cloud-Init.sh` — установка и настройка `cloud-init` для работы с metadata MWS.
- `7-Sysprep.sh` — подготовка golden image. Необратимо.

---

## Где смотреть логи

```
linux/logs/3-Diagnostic_v4.1_*.log
linux/logs/4-Migration_v4.1_*.log
linux/logs/5-Post-Migration_v4.1_*.log
linux/logs/6-Cloud-Init_v4.1_*.log
linux/logs/7-Sysprep_v4.1_*.log
```

Логи полезны для поддержки или самостоятельного анализа причин завершения работы скрипта. В конце каждого лога — итоговая сводка: что выполнено, что пропущено, что пошло не так.

---

## Если что-то пошло не так

**ВМ не грузится в KVM**
Первым делом посмотрите серийные логи ВМ. В панели MWS Cloud Platform
откройте ВМ, вкладка «Серийные логи». Там видно вывод UEFI, GRUB, ядра
Linux, cloud-init — по последним строкам можно понять, на какой стадии
упала загрузка.

Что искать:
- **Пусто, ни одной строки** — UEFI не запускает загрузчик. Проблема
  с ESP или fallback-загрузчиком.
- **GRUB-меню или строка «Booting ...»** — GRUB работает. Проблема
  в ядре или initramfs.
- **«Kernel panic — not syncing»** — ядро загрузилось, но не смонтировало
  корень. Скорее всего модули virtio не попали в initramfs.
- **«dracut-initqueue timeout»** — то же самое.
- **«grub rescue>»** — GRUB не нашёл `grub.cfg` или раздел `/boot`.

Если по логам не получается понять причину — приложите снимок серийных
логов и лог `4-Migration_v4.1_*.log`, обратитесь в поддержку MWS Cloud
Platform. Клиент не может интерактивно зайти в консоль ВМ, но серийные
логи дают представление о стадии сбоя.

Важно: буфер серийных логов хранится только пока ВМ запущена. При
выключении он очищается. Если ВМ уже перезагружена — старые логи
потеряны.

**Скрипт упал с `AbortUnsupportedFS`**
Корневая файловая система не поддерживается. Поддерживаются: `ext4`, `xfs`, `btrfs`.

**Скрипт упал с `AbortLVM`**
Корень на LVM. Toolkit не умеет мигрировать LVM-разметку в автоматическом режиме. Требуется ручная подготовка или конвертация в GPT с прямыми разделами.

**Скрипт упал с `AbortEncrypted`**
Корень под LUKS. Расшифруйте том перед миграцией: `cryptsetup luksClose`, конвертация в незашифрованный том.

**Скрипт упал с `AbortNoEFI`**
GPT-диск без ESP. Разметка повреждена, нужна ручная правка через `sgdisk` или `gdisk`.

**Скрипт упал с `AbortNoPartitionTool`**
В системе нет ни `sgdisk`, ни `parted`. Установите: `apt install gdisk parted` или `dnf install gdisk parted`.

**Скрипт упал с `AbortNoInitramfsTool`**
Нет ни `dracut`, ни `initramfs-tools`, ни `mkinitcpio`. Установите: `apt install initramfs-tools` или `dnf install dracut`.

**Скрипт упал с `AbortLegacyDistro`**
EOL-дистрибутив (CentOS 7, Debian 10 и т.д.). Toolkit не поддерживает их официально. Обновите дистрибутив или разверните чистую ВМ в KVM и перенесите данные.

**SSH не подключается**
Проверьте правило файрвола для порта 22 — оно должно быть открыто для вашего IP. Через поддержку MWS Cloud Platform запросите текущее состояние экрана ВМ, чтобы убедиться, что ОС загрузилась.

**cloud-init не применяет metadata**
Проверьте, что `cloud-init` установлен: `cloud-init --version`. Проверьте, что конфиги на месте: `ls /etc/cloud/cloud.cfg.d/99-mws-*`. Проверьте статус: `cloud-init status`. Логи cloud-init — `/var/log/cloud-init.log` и `journalctl -u cloud-init`.

**Можно ли запускать скрипты повторно?**
Да, они идемпотентны. На уже GPT-диске `4-Migration.sh` пропустит конвертацию, выполнит только недостающие шаги.

**Как понять, что миграция прошла успешно?**
ВМ загружается в KVM, SSH работает, `lsblk` показывает корень на `virtio`-устройстве. Скрипт `5-Post-Migration.sh` завершается без оставшихся проблем.

**Какого типа должна быть ссылка на образ?**
Только Path-Style PreSigned URL, вида `https://storage.mwsapis.ru/xxx/disk.vmdk?X-Amz-...`. Virtual-Hosted-Style не принимается.

---