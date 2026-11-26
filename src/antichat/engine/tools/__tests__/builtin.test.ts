import {
  calculatorTool,
  evaluateExpression,
  formatNumber,
} from '../builtin/calculator';
import {
  addToDate,
  dateTimeTool,
  daysBetween,
  parseDate,
  upcomingDatesLine,
  RELATIVE_DATE,
} from '../builtin/datetime';
import {formatDuration, parseDuration, setTimerTool} from '../builtin/timer';
import {
  convertUnits,
  convertUnitsTool,
  parseConversion,
} from '../builtin/units';
import {
  createWeatherTool,
  describeWeatherCode,
  unitForLocale,
  type FetchLike,
} from '../builtin/weather';

const now = new Date(2026, 10, 24, 10, 0, 0); // Tuesday
const context = {now, locale: 'en-GB'};

describe('calculator', () => {
  it.each([
    ['17 x 23', 391],
    ['17 times 23', 391],
    ['2^10', 1024],
    ['2**3**2', 512],
    ['15% of 80', 12],
    ['200 + 10%', 220],
    ['1,250.50 * 2', 2501],
    ['sqrt(16) + abs(-3)', 7],
    ['(3 + 4) * 2 - 6 / 3', 12],
    ['10 mod 3', 1],
    ['5!', 120],
    ['max(1, 2, 9)', 9],
    ['2(3+4)', 14],
    ['What is 12 divided by 4?', 3],
    ['-2^2', 4],
    ['3 squared plus 4 squared', 25],
  ])('%s = %s', (expression, expected) => {
    expect(evaluateExpression(expression)).toBeCloseTo(expected, 9);
  });

  it('formats without float noise', () => {
    expect(formatNumber(0.1 + 0.2)).toBe('0.3');
    expect(formatNumber(1 / 3)).toBe('0.3333333333');
    expect(formatNumber(391)).toBe('391');
  });

  it('rejects what is not maths', () => {
    expect(() => evaluateExpression('1/0')).toThrow('division by zero');
    expect(() => evaluateExpression('process.exit(1)')).toThrow();
    expect(() => evaluateExpression('2 +')).toThrow('incomplete');
  });

  it('returns a card', async () => {
    const out = await calculatorTool.execute(
      {expression: '1249 * 0.19'},
      context,
    );
    expect(out).toEqual({
      text: '1249 * 0.19 = 237.31',
      card: {
        type: 'calculator',
        expression: '1249 * 0.19',
        result: '237.31',
        value: 237.31,
      },
    });
    expect(
      (await calculatorTool.execute({expression: 'abc'}, context)).isError,
    ).toBe(true);
    expect(calculatorTool.normalize!({expr: '1+1'}, context)).toEqual({
      expression: '1+1',
    });
  });
});

describe('unit converter', () => {
  it('converts across the common quantities', () => {
    expect(convertUnits(5, 'mi', 'km').result).toBeCloseTo(8.04672, 5);
    expect(convertUnits(72, 'f', 'c').result).toBeCloseTo(22.2222, 3);
    expect(convertUnits(100, 'Celsius', 'Fahrenheit').result).toBeCloseTo(
      212,
      6,
    );
    expect(convertUnits(0, 'c', 'kelvin').result).toBeCloseTo(273.15, 6);
    expect(convertUnits(2, 'cups', 'ml').result).toBeCloseTo(473.18, 1);
    expect(convertUnits(180, 'lbs', 'kg').result).toBeCloseTo(81.647, 2);
    expect(convertUnits(100, 'km/h', 'mph').result).toBeCloseTo(62.137, 2);
    expect(convertUnits(1, 'GB', 'MB').result).toBe(1000);
    expect(convertUnits(90, 'minutes', 'hours').result).toBe(1.5);
  });

  it('refuses currencies and mixed quantities with a reason', () => {
    expect(() => convertUnits(10, 'usd', 'eur')).toThrow(
      'currencies need live exchange rates',
    );
    expect(() => convertUnits(1, 'kg', 'km')).toThrow(
      'cannot convert mass (kg) to length (km)',
    );
    expect(() => convertUnits(1, 'florps', 'km')).toThrow(
      'unknown unit "florps"',
    );
  });

  it('parses typed conversions and one-field arguments', async () => {
    expect(parseConversion('convert 3.5 cups to ml')).toEqual({
      value: 3.5,
      from: 'cups',
      to: 'ml',
    });
    expect(parseConversion('5 miles in km?')).toEqual({
      value: 5,
      from: 'miles',
      to: 'km',
    });
    expect(
      convertUnitsTool.normalize!({from: '5 mi', to: 'km'}, context),
    ).toEqual({
      value: 5,
      from: 'mi',
      to: 'km',
    });
    const out = await convertUnitsTool.execute(
      {value: 5, from: 'mi', to: 'km'},
      context,
    );
    expect(out.text).toBe('5 mi = 8.04672 km');
    expect(out.card).toMatchObject({type: 'conversion', quantity: 'length'});
  });
});

describe('date and time', () => {
  it('parses the dates people and models write', () => {
    const iso = (text: string) => {
      const date = parseDate(text, now)!;
      return `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
    };
    expect(iso('2026-12-01')).toBe('2026-12-1');
    expect(iso('tomorrow')).toBe('2026-11-25');
    expect(iso('Friday')).toBe('2026-11-27');
    expect(iso('next friday')).toBe('2026-12-4');
    expect(iso('last sunday')).toBe('2026-11-22');
    expect(iso('in 3 weeks')).toBe('2026-12-15');
    expect(iso('25 December')).toBe('2026-12-25');
    expect(iso('Jan 5')).toBe('2027-1-5');
    expect(parseDate('whenever', now)).toBeNull();
  });

  it('does date arithmetic', () => {
    expect(addToDate(new Date(2026, 0, 31), 1, 'months').getDate()).toBe(28);
    expect(daysBetween(now, new Date(2026, 11, 25))).toBe(31);
  });

  it('answers through the tool with a card', async () => {
    const add = await dateTimeTool.execute(
      {action: 'add', date: 'today', amount: 10, unit: 'days'},
      context,
    );
    expect(add.text).toBe(
      '2026-11-24 +10 days = Friday, 4 December 2026 (2026-12-04).',
    );
    expect(add.card).toMatchObject({
      type: 'datetime',
      iso: '2026-12-04',
      daysFromToday: 10,
    });
    const diff = await dateTimeTool.execute(
      {action: 'difference', date: '2026-11-24', other_date: '2026-12-25'},
      context,
    );
    expect(diff.text).toContain('31 days (4 weeks and 3 days)');
    const weekday = await dateTimeTool.execute(
      {action: 'weekday', date: '2026-12-25'},
      context,
    );
    expect(weekday.text).toBe('2026-12-25 is a Friday.');
    const clock = await dateTimeTool.execute({action: 'now'}, context);
    expect(clock.text).toBe('It is Tuesday, 24 November 2026, 10:00.');
    expect(
      (
        await dateTimeTool.execute(
          {action: 'add', date: 'gibberish', amount: 1},
          context,
        )
      ).isError,
    ).toBe(true);
    expect(dateTimeTool.normalize!({amount: 3, unit: 'day'}, context)).toEqual({
      amount: 3,
      unit: 'days',
      action: 'add',
    });
  });

  it('builds the date table small models need', () => {
    expect(upcomingDatesLine(now)).toBe(
      'Dates: yesterday Mon 2026-11-23; today Tue 2026-11-24; tomorrow Wed 2026-11-25; Thu 2026-11-26; Fri 2026-11-27; Sat 2026-11-28; Sun 2026-11-29; next week: Mon 2026-11-30, Tue 2026-12-01, Wed 2026-12-02, Thu 2026-12-03, Fri 2026-12-04, Sat 2026-12-05, Sun 2026-12-06. "This week" started Mon 2026-11-23.',
    );
    expect(
      RELATIVE_DATE.test('Put lunch with Maria on Friday in my calendar'),
    ).toBe(true);
    expect(RELATIVE_DATE.test('Was mache ich morgen?')).toBe(true);
    expect(RELATIVE_DATE.test('What is the capital of Australia?')).toBe(false);
  });
});

describe('timer', () => {
  it('parses durations', () => {
    expect(parseDuration('10 min')).toBe(600);
    expect(parseDuration('1h 30m')).toBe(5400);
    expect(parseDuration('45 seconds')).toBe(45);
    expect(parseDuration('1:30')).toBe(90);
    expect(parseDuration('90')).toBe(90);
    expect(parseDuration('soon')).toBeNull();
    expect(formatDuration(5430)).toBe('1 h 30 min 30 s');
  });

  it('returns a timer payload the native layer can schedule', async () => {
    const out = await setTimerTool.execute(
      {duration: '10 min', label: 'pasta'},
      context,
    );
    expect(out.text).toBe('Timer started: 10 min (pasta).');
    expect(out.card).toEqual({
      type: 'timer',
      kind: 'timer',
      label: 'pasta',
      durationSeconds: 600,
      firesAt: '2026-11-24T10:10:00',
      createdAt: '2026-11-24T10:00:00',
    });
    const alarm = await setTimerTool.execute({at: '07:30'}, context);
    expect(alarm.text).toBe('Alarm set for 07:30 tomorrow.');
    expect(alarm.card).toMatchObject({
      kind: 'alarm',
      firesAt: '2026-11-25T07:30:00',
    });
    expect((await setTimerTool.execute({}, context)).isError).toBe(true);
    expect(
      (await setTimerTool.execute({duration: '30 days'}, context)).isError,
    ).toBe(true);
    expect(setTimerTool.normalize!({minutes: 5}, context)).toEqual({
      duration: '300',
    });
  });
});

describe('weather', () => {
  const fetchImpl: FetchLike = async url => ({
    ok: true,
    status: 200,
    json: async () =>
      url.includes('geocoding')
        ? {
            results: [
              {
                name: 'Lisbon',
                country: 'Portugal',
                latitude: 38.72,
                longitude: -9.13,
              },
            ],
          }
        : {
            current: {
              time: '2026-11-24T10:00',
              temperature_2m: 17.2,
              apparent_temperature: 16.1,
              relative_humidity_2m: 71,
              wind_speed_10m: 14.4,
              weather_code: 61,
            },
            daily: {
              time: ['2026-11-24', '2026-11-25'],
              weather_code: [61, 2],
              temperature_2m_max: [18.3, 19.9],
              temperature_2m_min: [12.1, 11.4],
              precipitation_probability_max: [80, 10],
            },
          },
  });

  it('returns a weather card and text the model can answer from', async () => {
    const out = await createWeatherTool(fetchImpl).execute(
      {place: 'Lisbon'},
      context,
    );
    expect(out.text.split('\n')[0]).toBe(
      'Weather in Lisbon, Portugal (observed 2026-11-24T10:00): 17 °C, light rain, feels like 16 °C, wind 14 km/h, humidity 71%.',
    );
    expect(out.card).toMatchObject({
      type: 'weather',
      place: 'Lisbon',
      unit: 'C',
      current: {temperatureC: 17.2, icon: 'rain'},
      days: [
        {
          date: '2026-11-24',
          minC: 12.1,
          maxC: 18.3,
          icon: 'rain',
          precipitationChance: 80,
        },
        {date: '2026-11-25', icon: 'partly'},
      ],
    });
    expect(out.sources?.[0].site).toBe('open-meteo.com');
  });

  it('fails in one line when the place is unknown or the service is down', async () => {
    const empty: FetchLike = async () => ({
      ok: true,
      status: 200,
      json: async () => ({}),
    });
    expect(
      await createWeatherTool(empty).execute({place: 'Nowhereville'}, context),
    ).toEqual({
      text: 'weather: no place called "Nowhereville" was found.',
      isError: true,
    });
    const down: FetchLike = async () => ({
      ok: false,
      status: 503,
      json: async () => ({}),
    });
    expect(
      (await createWeatherTool(down).execute({place: 'Lisbon'}, context))
        .isError,
    ).toBe(true);
  });

  it('maps codes and locales', () => {
    expect(describeWeatherCode(0)).toEqual({
      condition: 'clear sky',
      icon: 'clear',
    });
    expect(describeWeatherCode(95).icon).toBe('storm');
    expect(unitForLocale('en-US')).toBe('F');
    expect(unitForLocale('de-DE')).toBe('C');
  });
});
