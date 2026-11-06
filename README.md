# podkop-vpn-failover-owrt

[English](README.en.md)

Поддерживаемая копия [podkop-vpn-failover](https://github.com/SVTagan/podkop-vpn-failover) с установщиком для OpenWrt 24.10 и 25.12.

Проект независимый и не связан с разработчиками Podkop. Проверяет AmneziaWG и переключает выбранную VPN-секцию Podkop или Forkozz (NetShift) на рабочий резерв. Версия 0.2.0 проверена на Xiaomi AX3000T (OpenWrt 24.10.5, Forkozz/NetShift 0.9.12): реальное переключение, автоматический переход при отключении активного AWG, откат, procd и журнал LuCI. Подробности и ограничения — в [VALIDATION.md](VALIDATION.md). Авторские права на исходный проект сохраняются, см. [LICENSE](LICENSE).

## Совместимость

- **OpenWrt 24.10.x** — менеджер пакетов `opkg`.
- **OpenWrt 25.12.x** — менеджер пакетов `apk`.
- Требуются Podkop или Forkozz (NetShift) в режиме VPN и AmneziaWG-интерфейсы с именами `awg*`.
- Требуются `uci`, procd, `curl`, `jq`, `awk`, `sort`, `cut`, `sed`, `grep` и `logger`.

Установщик автоматически выбирает `apk` или `opkg` по наличию команды. Он использует выбранный менеджер для проверки пакетов, обновления индексов и установки `curl`, `jq` / необязательного `luci-app-commands`.

**Важно:** исходные сценарии инициализации OpenWrt остаются на базе procd. Используется procd; DNS, списки маршрутизации и настройки самих туннелей failover не редактирует. Reload движка может кратковременно затронуть соединения остальных секций.

## Что делает failover

- обнаруживает UCI-интерфейсы `awg*` с протоколом `amneziawg`;
- проверяет реальный HTTPS-трафик через каждый интерфейс;
- после трёх подряд неудачных проверок активного VPN ищет резерв;
- требует две успешные проверки резервного интерфейса;
- меняет только `interface` выбранной секции `podkop` или `netshift`, вызывает штатный reload и проверяет `${section}-out` в sing-box;
- временно откладывает ранее отказавшие интерфейсы;
- использует стартовую задержку 120 секунд и безопасно ведёт себя при отсутствии рабочего резерва.

Сервис после **первой установки** специально остаётся остановленным и отключённым. При **обновлении** состояние работы и автозапуска существующего сервиса сохраняется.

## Журнал в интерфейсе

LuCI → **Службы / Services → VPN Failover**. Страница обновляется каждые 5 секунд: время, движок и секция, переход `awg0 → awg1`, результат и подробности. Записываются проверки резервов, начало перехода, подтверждённый успех, ошибки, откат, внешние изменения и отсутствие резервов. Новые записи сверху. RPC доступен только авторизованному пользователю с ACL `vpn-failover`, только для чтения.

Журнал: последние 200 операций в `/tmp/podkop-vpn-failover/operations.tsv`, без записи на флеш. Перезапуск службы сохраняет записи; перезагрузка роутера очищает их. CLI: `podkop-vpn-failover history`; JSON: `podkop-vpn-failover dashboard`. Кнопка Logs в Custom Commands продолжает показывать системный logread.

## Выбор Podkop или Forkozz

По умолчанию `backend=auto`, секция `main`. При наличии конфигурации только одного движка он определяется автоматически. Если найдены оба движка или ни одного, автоматическое переключение не запускается. Podkop и Forkozz не следует запускать одновременно: они конкурируют за DNS и перехват трафика.

Пример настройки **после согласования изменений на роутере**:

```sh
[ -e /etc/config/vpn_failover ] || touch /etc/config/vpn_failover
uci set vpn_failover.main=settings
uci set vpn_failover.main.backend='forkozz'
uci set vpn_failover.main.section='main'
uci commit vpn_failover
```

Для Podkop: `backend='podkop'`. Для другой именованной секции укажи её UCI-имя вместо `main`. После изменения настроек перезапусти уже работающий failover через `podkop-vpn-failover-control restart`. Первый запуск после установки: `podkop-vpn-failover-control start`.

Forkozz: используется `/etc/config/netshift`, `netshift.<section>.connection_type=vpn`, `netshift.<section>.interface`, `/usr/bin/netshift reload`. Учитывается `settings.config_path`. Отключённые секции и режим proxy не переключаются. Это резервирование существующих `awg*` интерфейсов; выбор серверов прокси и подписок сюда не входит. За один экземпляр службы обслуживается одна выбранная секция. При неудаче проверяется восстановление предыдущей привязки; если откат не подтверждён, текущий перебор прекращается.

## Установка

На роутере:

```sh
uclient-fetch -q -O /tmp/pvf-install.sh https://raw.githubusercontent.com/TMN88/podkop-vpn-failover-owrt/main/install.sh && sh /tmp/pvf-install.sh
```

Можно также скачать скрипт через `curl` или `wget`, затем выполнить `sh /tmp/pvf-install.sh`.

Для отключения автоматического добавления команд LuCI перед запуском установите `INSTALL_LUCI_COMMANDS=0` в окружении.

После установки сначала проверьте обнаружение и состояние VPN:

```sh
podkop-vpn-failover test
podkop-vpn-failover status
```

После проверки включите сервис:

```sh
podkop-vpn-failover-control start
```

## Управление и логи

Команды доступны через CLI; если установлен `luci-app-commands`, также появятся в LuCI → System → Custom Commands.

```sh
podkop-vpn-failover status
podkop-vpn-failover test
podkop-vpn-failover config
podkop-vpn-failover logs
logread | grep podkop-vpn-failover
```

## Проверки

Workflow CI настроен на `sh -n`, функциональные mock-тесты `python3 tests/test_backend.py` и тест интерфейса `node tests/test_view.js`. Локально выполнены те же проверки с BusyBox ash и jq 1.8.1; результат описан в VALIDATION.md. CI для этих изменений ещё не запускался. Функциональные тесты на реальных роутерах с OpenWrt 25.12 должны быть выполнены отдельно; публикация совместимости установщика сама по себе не означает, что failover проверен в живой сети на каждой платформе.

## Благодарности и лицензия

Оригинальный проект и логика принадлежат исходным авторам. См. [репозиторий оригинала](https://github.com/SVTagan/podkop-vpn-failover) и лицензию MIT в [LICENSE](LICENSE).
