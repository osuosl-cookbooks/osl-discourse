require_relative '../../spec_helper'
require_relative '../../../libraries/helpers'

RSpec.describe OslDiscourse::Cookbook::Helpers do
  let(:dummy_class) do
    Class.new { include OslDiscourse::Cookbook::Helpers }
  end

  subject { dummy_class.new }

  describe '#discourse_cron_utc' do
    context 'America/Los_Angeles, during PDT (summer)' do
      # 2026-07-06 is a Monday in PDT (UTC-7)
      let(:today) { Date.new(2026, 7, 6) }

      it 'shifts Mon 11:10 to Mon 18:10 UTC' do
        expect(subject.discourse_cron_utc('Mon', 11, 10, 'America/Los_Angeles', today: today))
          .to eq(weekday: 'Mon', hour: 18, minute: 10)
      end

      it 'rolls weekday forward when the local time crosses midnight UTC' do
        # Sun 22:00 PDT (UTC-7) → Mon 05:00 UTC
        expect(subject.discourse_cron_utc('Sun', 22, 0, 'America/Los_Angeles', today: today))
          .to eq(weekday: 'Mon', hour: 5, minute: 0)
      end
    end

    context 'America/Los_Angeles, during PST (winter)' do
      # 2026-01-05 is a Monday in PST (UTC-8)
      let(:today) { Date.new(2026, 1, 5) }

      it 'shifts Mon 11:10 to Mon 19:10 UTC' do
        expect(subject.discourse_cron_utc('Mon', 11, 10, 'America/Los_Angeles', today: today))
          .to eq(weekday: 'Mon', hour: 19, minute: 10)
      end

      it 'rolls weekday forward when the local time crosses midnight UTC' do
        # Mon 22:00 PST (UTC-8) → Tue 06:00 UTC
        expect(subject.discourse_cron_utc('Mon', 22, 0, 'America/Los_Angeles', today: today))
          .to eq(weekday: 'Tue', hour: 6, minute: 0)
      end
    end

    context 'UTC input' do
      it 'is an identity transform' do
        expect(subject.discourse_cron_utc('Fri', 3, 30, 'UTC', today: Date.new(2026, 5, 15)))
          .to eq(weekday: 'Fri', hour: 3, minute: 30)
      end
    end

    context 'numeric weekday inputs' do
      let(:today) { Date.new(2026, 7, 6) }

      it 'accepts 0 as Sunday' do
        # Sun 22:00 PDT → Mon 05:00 UTC
        expect(subject.discourse_cron_utc(0, 22, 0, 'America/Los_Angeles', today: today))
          .to eq(weekday: 'Mon', hour: 5, minute: 0)
      end

      it 'accepts 7 as Sunday (cron convention)' do
        expect(subject.discourse_cron_utc(7, 22, 0, 'America/Los_Angeles', today: today))
          .to eq(weekday: 'Mon', hour: 5, minute: 0)
      end
    end

    it 'rejects unknown weekday names' do
      expect do
        subject.discourse_cron_utc('NotADay', 1, 0, 'UTC')
      end.to raise_error(ArgumentError, /invalid weekday/)
    end
  end
end
