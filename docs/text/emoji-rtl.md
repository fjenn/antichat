# Mixed-script sample (authored for AntiChat, CC0 1.0)

This file exercises text rendering and tokenisation. It is plain English prose with emoji 😀, skin tones 👋🏽, flags 🇳🇱 🇯🇵, and ZWJ sequences such as 👩‍💻, 👨‍👩‍👧, 🏳️‍🌈 and 🧑🏾‍🚀. Keycaps look like 1️⃣ 2️⃣ #️⃣, and a variation selector turns ☺ into ☺️.

A paragraph about the weather: the morning was grey ☁️, then the sun came out ☀️ and everyone went for a walk 🚶. We stopped for coffee ☕ and a croissant 🥐, talked about books 📚, and came home before the rain 🌧️ started again.

## Right-to-left lines

Arabic: مرحبا بك في AntiChat. هذا نص تجريبي يحتوي على أرقام 123 وكلمة English في المنتصف.
Hebrew: שלום וברוכים הבאים. זהו טקסט לדוגמה עם מספרים 456 ומילה English באמצע.
Mixed direction: The word «سلام» means peace, and «שלום» does too.

## CJK

Chinese: 你好，世界。这是一个用于测试的简短段落，包含标点符号和数字 2026。
Japanese: こんにちは、世界。これはテスト用の短い文章です。カタカナ、ひらがな、漢字。
Korean: 안녕하세요, 세계. 이것은 테스트용 짧은 문장입니다.

## Other scripts and symbols

Greek: Καλημέρα κόσμε. Cyrillic: Привет, мир. Devanagari: नमस्ते दुनिया। Thai: สวัสดีชาวโลก
Math and symbols: ∑ ∫ √ ≤ ≥ ≠ ∞ → ← ↔ © ® ™ € £ ¥ ° ± × ÷ — – … “quotes” ‘single’.
Combining marks: é (precomposed) vs é (e + U+0301); Zalgo-lite: å̧ ö̲.

## Code

```python
def greet(name: str) -> str:
    # Emoji in a string literal: 🎉
    return f"Hello, {name}! مرحبا 你好"

for who in ["Sam", "Priya", "Max", "Riley"]:
    print(greet(who))
```

Inline code `let x = "👩‍💻"` and a URL-like string https://example.org/path?q=1&r=2 end the sample.
