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

  describe '#discourse_backup_schedule_utc' do
    # 2026-07-06 is a Monday in PDT (UTC-7); 2026-01-05 a Monday in PST (UTC-8).
    let(:pdt) { Date.new(2026, 7, 6) }
    let(:pst) { Date.new(2026, 1, 5) }

    context 'daily schedule' do
      it "keeps weekday '*' and shifts 02:30 PDT to 09:30 UTC" do
        expect(subject.discourse_backup_schedule_utc('*', 2, 30, 'America/Los_Angeles', today: pdt))
          .to eq(weekday: '*', hour: 9, minute: 30)
      end

      it "keeps weekday '*' and shifts 02:30 PST to 10:30 UTC" do
        expect(subject.discourse_backup_schedule_utc('*', 2, 30, 'America/Los_Angeles', today: pst))
          .to eq(weekday: '*', hour: 10, minute: 30)
      end

      it "treats 'daily' the same as '*'" do
        expect(subject.discourse_backup_schedule_utc('daily', 2, 30, 'America/Los_Angeles', today: pdt))
          .to eq(weekday: '*', hour: 9, minute: 30)
      end
    end

    context 'weekly schedule' do
      it 'delegates to discourse_cron_utc, converting both weekday and time' do
        # Sun 22:00 PDT (UTC-7) → Mon 05:00 UTC
        expect(subject.discourse_backup_schedule_utc('Sun', 22, 0, 'America/Los_Angeles', today: pdt))
          .to eq(weekday: 'Mon', hour: 5, minute: 0)
      end
    end
  end

  describe '#discourse_container_exists?' do
    before { require 'docker' }

    it 'returns true when the container is found' do
      allow(Docker::Container).to receive(:get).with('forum').and_return(double)
      expect(subject.discourse_container_exists?('forum')).to be true
    end

    it 'returns false on NotFoundError' do
      allow(Docker::Container).to receive(:get).with('forum')
                                               .and_raise(Docker::Error::NotFoundError)
      expect(subject.discourse_container_exists?('forum')).to be false
    end

    it 'returns false on any other docker error (daemon down, gem missing, etc.)' do
      allow(Docker::Container).to receive(:get).with('forum')
                                               .and_raise(StandardError, 'docker daemon unreachable')
      expect(subject.discourse_container_exists?('forum')).to be false
    end
  end
end
