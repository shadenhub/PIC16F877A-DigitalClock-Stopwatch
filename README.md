# PIC16F877A Digital Clock, Stopwatch & HSLM Display

> 🎓 **Student Project** — Computer Engineering, Written in PIC Assembly Language

A bare-metal embedded systems project built on the **PIC16F877A** microcontroller, driving a **Nokia 5110 LCD** over hardware SPI. The system features a navigable main menu with three functional modes: a real-time clock, a stopwatch, and a horizontal scrolling animation.

---

## 👩‍💻 Team

| Name | Role |
|------|------|
| **Shaden** | **Team Leader** |
| Heba | Member |
| Leen | Member |
| Mayar | Member |

---

## ✨ Features

- **Real-Time Clock** — 24-hour format (HH:MM:SS) with blinking colon separators
- **Stopwatch** — Start/Stop control via ENTER button, same HH:MM:SS format
- **HSLM Animation** — Horizontal scrolling marquee animation across the LCD
- **Main Menu** — Navigate between modes using 3 push buttons (SELECT, ENTER, BACK)
- **Timer0 ISR** — Interrupt-driven timing (~1ms ticks at 4MHz)
- **Hardware SPI** — Fast LCD communication via MSSP module

---

## 🔧 Hardware

| Component | Details |
|-----------|---------|
| Microcontroller | PIC16F877A |
| Display | Nokia 5110 LCD (PCD8544 controller) |
| Clock Speed | 4 MHz |
| Communication | SPI via MSSP module |

---

## 📌 Pin Connections

| Signal | PIC Pin | Description |
|--------|---------|-------------|
| LCD RST | RD0 | Reset (active low) |
| LCD DC | RD1 | Data / Command select |
| LCD CE | RD2 | Chip Enable (active low) |
| SCLK | RC3 | SPI Clock |
| SDIN | RC5 | SPI Data |
| BTN SELECT | RB4 | Cycle menu items |
| BTN ENTER | RB5 | Open item / Start-Stop stopwatch |
| BTN BACK | RB6 | Return to main menu |

---

## 🗂️ System Modes

| Mode ID | Name | Description |
|---------|------|-------------|
| `0xFF` | Main Menu | Boot screen, navigate with SELECT/ENTER/BACK |
| `0x00` | Clock | Live 24-hour clock, starts at 12:00:00 |
| `0x01` | Stopwatch | Counts up, controlled by ENTER button |
| `0x02` | HSLM | Horizontal scrolling sprite animation |

---

## ⚙️ How It Works

- **Timer0** is configured with a 1:256 prescaler at 4MHz, firing an ISR approximately every 1ms
- Every **77 ticks (~1 second)**, the clock and stopwatch are updated
- The **HSLM animation** runs every 8 ticks, moving the sprite one pixel left and wrapping at column 48
- **Button inputs** are active-low on PORTB with software debounce and lock flags to prevent repeat-firing while held

---

## 🛠️ Build & Flash

1. Open `project.asm` in **MPLAB IDE**
2. Select **PIC16F877A** as the target device
3. Build the project to generate `project.HEX`
4. Flash using **PICkit** or any compatible programmer

---

## 📁 File Structure

```
├── project.asm   # Full assembly source code
├── README.md     # Project documentation
└── LICENSE       # MIT License
```

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
