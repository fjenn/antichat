/**
 * Calculator: a small recursive-descent evaluator (no `eval`, no
 * dependency). Works offline. Accepts what people and small models type:
 * "17 x 23", "15% of 80", "2^10", "sqrt(2)", "1,250.50 * 3", "12 times 4".
 */
import type {CalculatorCard} from '../cards';
import type {AntichatTool} from '../types';

const FUNCTIONS: Record<string, (...values: number[]) => number> = {
  sqrt: Math.sqrt,
  cbrt: Math.cbrt,
  abs: Math.abs,
  round: (value, digits = 0) => {
    const factor = 10 ** digits;
    return Math.round(value * factor) / factor;
  },
  floor: Math.floor,
  ceil: Math.ceil,
  sin: Math.sin,
  cos: Math.cos,
  tan: Math.tan,
  asin: Math.asin,
  acos: Math.acos,
  atan: Math.atan,
  ln: Math.log,
  log: (value, base) =>
    base === undefined ? Math.log10(value) : Math.log(value) / Math.log(base),
  log10: Math.log10,
  log2: Math.log2,
  exp: Math.exp,
  min: Math.min,
  max: Math.max,
  pow: Math.pow,
  mod: (a, b) => a % b,
};

const CONSTANTS: Record<string, number> = {
  pi: Math.PI,
  π: Math.PI,
  e: Math.E,
  tau: Math.PI * 2,
};

const WORDS: Array<[RegExp, string]> = [
  [/\bdivided by\b/gi, '/'],
  [/\b(?:multiplied by|times)\b/gi, '*'],
  [/\bplus\b/gi, '+'],
  [/\bminus\b/gi, '-'],
  [/\bto the power of\b/gi, '^'],
  [/\bsquared\b/gi, '^2'],
  [/\bcubed\b/gi, '^3'],
  [/\bsquare root of\b/gi, 'sqrt'],
  [/\bpercent\b/gi, '%'],
  [/\bmod(?:ulo)?\b/gi, ' mod '],
];

/** Normalise typed maths to the grammar below. */
export function normalizeExpression(input: string): string {
  let text = input
    .replace(/[×✕·]/g, '*')
    .replace(/[÷]/g, '/')
    .replace(/[−–—]/g, '-')
    .replace(/\*\*/g, '^')
    .replace(/[=?]\s*$/g, '')
    .replace(/^\s*(?:what is|what's|calculate|compute|evaluate)\s+/i, '');
  for (const [pattern, replacement] of WORDS) {
    text = text.replace(pattern, replacement);
  }
  // "17 x 23" — an x between numbers or brackets is a multiplication sign.
  text = text.replace(/(?<=[\d)]\s*)x(?=\s*[\d(.])/gi, '*');
  // Thousands separators: 1,250.50 → 1250.50 (never inside a function call
  // with two short arguments such as max(1,2)).
  text = text.replace(/(?<=\d),(?=\d{3}(?!\d))/g, '');
  return text.trim();
}

class Parser {
  private index = 0;

  constructor(private readonly text: string) {}

  parse(): number {
    const value = this.expression();
    this.space();
    if (this.index < this.text.length) {
      throw new Error(
        `unexpected "${this.text.slice(this.index, this.index + 8)}"`,
      );
    }
    return value;
  }

  private space(): void {
    while (this.index < this.text.length && /\s/.test(this.text[this.index])) {
      this.index++;
    }
  }

  private peek(): string {
    this.space();
    return this.text[this.index] ?? '';
  }

  private eat(token: string): boolean {
    this.space();
    if (this.text.startsWith(token, this.index)) {
      this.index += token.length;
      return true;
    }
    return false;
  }

  private expression(): number {
    let value = this.term();
    for (;;) {
      if (this.eat('+')) {
        value += this.percentOperand(value);
      } else if (this.eat('-')) {
        value -= this.percentOperand(value);
      } else {
        return value;
      }
    }
  }

  /** "200 + 10%" means 200 + 10 % of 200, as on a pocket calculator. */
  private percentOperand(base: number): number {
    const start = this.index;
    const value = this.term();
    const consumed = this.text.slice(start, this.index).trim();
    if (/^\d+(\.\d+)?\s*%$/.test(consumed)) {
      return base * value;
    }
    return value;
  }

  private term(): number {
    let value = this.power();
    for (;;) {
      if (this.eat('*')) {
        value *= this.power();
      } else if (this.eat('/')) {
        const divisor = this.power();
        if (divisor === 0) {
          throw new Error('division by zero');
        }
        value /= divisor;
      } else if (/^mod\b/i.test(this.text.slice(this.index).trimStart())) {
        this.space();
        this.index += 3;
        value %= this.power();
      } else if (/^of\b/i.test(this.text.slice(this.index).trimStart())) {
        // "15% of 80"
        this.space();
        this.index += 2;
        value *= this.power();
      } else if (this.peek() === '(') {
        // implicit multiplication: 2(3+4)
        value *= this.power();
      } else {
        return value;
      }
    }
  }

  private power(): number {
    const base = this.unary();
    if (this.eat('^')) {
      return Math.pow(base, this.powerOperand());
    }
    return base;
  }

  private powerOperand(): number {
    // right associative: 2^3^2 = 2^9
    const value = this.unary();
    if (this.eat('^')) {
      return Math.pow(value, this.powerOperand());
    }
    return value;
  }

  private unary(): number {
    if (this.eat('-')) {
      return -this.unary();
    }
    if (this.eat('+')) {
      return this.unary();
    }
    return this.postfix();
  }

  private postfix(): number {
    let value = this.primary();
    for (;;) {
      if (this.eat('%')) {
        value /= 100;
      } else if (this.eat('!')) {
        value = factorial(value);
      } else {
        return value;
      }
    }
  }

  private primary(): number {
    this.space();
    if (this.eat('(')) {
      const value = this.expression();
      if (!this.eat(')')) {
        throw new Error('missing ")"');
      }
      return value;
    }
    const rest = this.text.slice(this.index);
    const number = /^(?:\d+\.?\d*(?:e[+-]?\d+)?|\.\d+)/i.exec(rest);
    if (number) {
      this.index += number[0].length;
      return Number(number[0]);
    }
    const name = /^[A-Za-zπ_]\w*/.exec(rest);
    if (name) {
      this.index += name[0].length;
      const key = name[0].toLowerCase();
      if (key in FUNCTIONS) {
        const args: number[] = [];
        if (this.eat('(')) {
          if (!this.eat(')')) {
            do {
              args.push(this.expression());
            } while (this.eat(',') || this.eat(';'));
            if (!this.eat(')')) {
              throw new Error('missing ")"');
            }
          }
        } else {
          args.push(this.unary());
        }
        return FUNCTIONS[key](...args);
      }
      if (key in CONSTANTS) {
        return CONSTANTS[key];
      }
      throw new Error(`unknown name "${name[0]}"`);
    }
    throw new Error(
      rest
        ? `unexpected "${rest.slice(0, 8)}"`
        : 'the expression is incomplete',
    );
  }
}

function factorial(value: number): number {
  if (!Number.isInteger(value) || value < 0 || value > 170) {
    throw new Error('factorial needs a whole number from 0 to 170');
  }
  let result = 1;
  for (let i = 2; i <= value; i++) {
    result *= i;
  }
  return result;
}

/** Evaluate an arithmetic expression. Throws with a one-line reason. */
export function evaluateExpression(input: string): number {
  const text = normalizeExpression(input);
  if (!text) {
    throw new Error('the expression is empty');
  }
  if (text.length > 300) {
    throw new Error('the expression is too long');
  }
  const value = new Parser(text).parse();
  if (!Number.isFinite(value)) {
    throw new Error('the result is not a finite number');
  }
  return value;
}

/** At most 10 significant digits, no trailing zeros, no float noise. */
export function formatNumber(value: number): string {
  if (Number.isInteger(value) && Math.abs(value) < 1e15) {
    return String(value);
  }
  const abs = Math.abs(value);
  if (abs !== 0 && (abs >= 1e15 || abs < 1e-6)) {
    return value.toExponential(6).replace(/\.?0+e/, 'e');
  }
  return String(Number(value.toPrecision(10)));
}

export const calculatorTool: AntichatTool = {
  name: 'calculator',
  description:
    'Evaluate an arithmetic expression exactly. Use for any calculation with more than two small numbers.',
  parameters: {
    type: 'object',
    properties: {
      expression: {
        type: 'string',
        description: 'Maths only, e.g. "1249 * 0.19" or "sqrt(2) + 15% of 80"',
        minLength: 1,
      },
    },
    required: ['expression'],
    additionalProperties: false,
  },
  kind: 'local',
  tier: 'always',
  keywords: ['math', 'maths', 'sum', 'multiply', 'divide', 'percent', 'tip'],
  timeoutMs: 2000,
  example: {expression: '17 * 23'},
  normalize: args => {
    const expression = args.expression ?? args.expr ?? args.input ?? args.query;
    return expression === undefined ? args : {expression};
  },
  async execute(args) {
    const expression = String(args.expression);
    try {
      const value = evaluateExpression(expression);
      const result = formatNumber(value);
      const card: CalculatorCard = {
        type: 'calculator',
        expression: normalizeExpression(expression),
        result,
        value,
      };
      return {text: `${card.expression} = ${result}`, card};
    } catch (error) {
      return {
        text: `calculator: ${(error as Error).message}. Pass maths only, e.g. "17 * 23".`,
        isError: true,
      };
    }
  },
};
