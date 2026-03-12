# ASB AI Governor — исходный код

## Быстрый старт (Termux на OnePlus 15)

```sh
# 1. Установить компилятор (один раз)
pkg update && pkg install clang

# 2. Скопировать src/ на устройство (уже внутри модуля)
cd /data/adb/modules/AutoSystemBoost/src

# 3. Собрать
sh build_termux.sh

# 4. Готово — бинарник уже в ../bin/
# При следующей перезагрузке service.sh запустит governor автоматически
```

## Файлы

| Файл | Назначение |
|---|---|
| asb_governor.c | Главный daemon, epoll event loop |
| asb_metrics.h  | Чтение sysfs метрик (battery/GPU/CPU/thermal) |
| asb_fsm.h      | Конечный автомат 5 состояний + гистерезис |
| asb_learner.h  | EMA learner, 168 слотов 24×7 |
| asb_writer.h   | Запись в sysfs без fork |
| asb_socket.h   | Unix socket управление |

## Управление (после сборки)

```sh
# Статус
/data/adb/modules/AutoSystemBoost/bin/asb_governor status

# Переключить профиль вручную
/data/adb/modules/AutoSystemBoost/bin/asb_governor profile:battery

# Посмотреть state файл
cat /dev/.asb/state

# Лог
cat /dev/.asb/governor.log
```

## Состояния FSM

| Состояние | Условие | CPU policy caps |
|---|---|---|
| DEEP_IDLE  | screen OFF | floor диапазона профиля |
| LIGHT_IDLE | screen ON, mA<90 | 15% диапазона |
| MODERATE   | load>1.5 или mA>150 | 45% диапазона |
| HEAVY      | GPU>35%, mA>180 | 75% диапазона |
| GAMING     | GPU>65%, mA>350 | ceil диапазона |
