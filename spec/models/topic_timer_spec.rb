# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TopicTimer, type: :model do
  fab!(:topic_timer) { Fabricate(:topic_timer) }
  fab!(:topic) { Fabricate(:topic) }
  fab!(:admin) { Fabricate(:admin) }

  before { freeze_time }

  context "validations" do
    describe '#status_type' do
      it 'should ensure that only one active public topic status update exists' do
        topic_timer.update!(topic: topic)
        Fabricate(:topic_timer, deleted_at: Time.zone.now, topic: topic)

        expect { Fabricate(:topic_timer, topic: topic) }
          .to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    describe '#execute_at' do
      describe 'when #execute_at is greater than #created_at' do
        it 'should be valid' do
          topic_timer = Fabricate.build(:topic_timer,
            execute_at: Time.zone.now + 1.hour,
            user: Fabricate(:user),
            topic: Fabricate(:topic)
          )

          expect(topic_timer).to be_valid
        end
      end

      describe 'when #execute_at is smaller than #created_at' do
        it 'should not be valid' do
          topic_timer = Fabricate.build(:topic_timer,
            execute_at: Time.zone.now - 1.hour,
            created_at: Time.zone.now,
            user: Fabricate(:user),
            topic: Fabricate(:topic)
          )

          expect(topic_timer).to_not be_valid
        end
      end
    end

    describe '#category_id' do
      describe 'when #status_type is publish_to_category' do
        describe 'when #category_id is not present' do
          it 'should not be valid' do
            topic_timer = Fabricate.build(:topic_timer,
              status_type: TopicTimer.types[:publish_to_category]
            )

            expect(topic_timer).to_not be_valid
            expect(topic_timer.errors).to include(:category_id)
          end
        end

        describe 'when #category_id is present' do
          it 'should be valid' do
            topic_timer = Fabricate.build(:topic_timer,
              status_type: TopicTimer.types[:publish_to_category],
              category_id: Fabricate(:category).id,
              user: Fabricate(:user),
              topic: Fabricate(:topic)
            )

            expect(topic_timer).to be_valid
          end
        end
      end
    end
  end

  context 'callbacks' do
    describe 'when #execute_at and #user_id are not changed' do
      it 'should not schedule another to update topic' do
        Jobs.expects(:enqueue_at).never
        Jobs.expects(:cancel_scheduled_job).never

        topic_timer.update!(topic: Fabricate(:topic))
      end
    end

    describe 'when #execute_at value is changed' do
      it 'reschedules the job' do
        Jobs.expects(:cancel_scheduled_job).with(
          :toggle_topic_closed, topic_timer_id: topic_timer.id
        )

        expect_enqueued_with(job: :toggle_topic_closed, args: { topic_timer_id: topic_timer.id, state: true }, at: 3.days.from_now) do
          topic_timer.update!(execute_at: 3.days.from_now, created_at: Time.zone.now)
        end
      end

      describe 'when execute_at is smaller than the current time' do
        it 'should enqueue the job immediately' do
          expect_enqueued_with(job: :toggle_topic_closed, args: { topic_timer_id: topic_timer.id, state: true }, at: Time.zone.now) do
            topic_timer.update!(
              execute_at: Time.zone.now - 1.hour,
              created_at: Time.zone.now - 2.hour
            )
          end
        end
      end
    end

    describe 'when user is changed' do
      it 'should update the job' do
        Jobs.expects(:cancel_scheduled_job).with(
          :toggle_topic_closed, topic_timer_id: topic_timer.id
        )

        expect_enqueued_with(job: :toggle_topic_closed, args: { topic_timer_id: topic_timer.id, state: true }, at: topic_timer.execute_at) do
          topic_timer.update!(user: admin)
        end
      end
    end

    describe 'when a open topic status update is created for an open topic' do
      fab!(:topic) { Fabricate(:topic, closed: false) }
      fab!(:topic_timer) do
        Fabricate(:topic_timer,
          status_type: described_class.types[:open],
          topic: topic
        )
      end

      before do
        Jobs.run_immediately!
      end

      it 'should close the topic' do
        topic_timer
        expect(topic.reload.closed).to eq(true)
      end

      describe 'when topic has been deleted' do
        it 'should not queue the job' do
          topic.trash!
          topic_timer

          expect(Jobs::ToggleTopicClosed.jobs).to eq([])
        end
      end
    end

    describe 'when a close topic status update is created for a closed topic' do
      fab!(:topic) { Fabricate(:topic, closed: true) }
      fab!(:topic_timer) do
        Fabricate(:topic_timer,
          status_type: described_class.types[:close],
          topic: topic
        )
      end

      before do
        Jobs.run_immediately!
      end

      it 'should open the topic' do
        topic_timer
        expect(topic.reload.closed).to eq(false)
      end

      describe 'when topic has been deleted' do
        it 'should not queue the job' do
          topic.trash!
          topic_timer

          expect(Jobs::ToggleTopicClosed.jobs).to eq([])
        end
      end
    end

    describe '#public_type' do
      [:close, :open, :delete].each do |public_type|
        it "is true for #{public_type}" do
          timer = Fabricate(:topic_timer, status_type: described_class.types[public_type])
          expect(timer.public_type).to eq(true)
        end
      end

      it "is true for publish_to_category" do
        timer = Fabricate(:topic_timer, status_type: described_class.types[:publish_to_category], category: Fabricate(:category))
        expect(timer.public_type).to eq(true)
      end

      described_class.private_types.keys.each do |private_type|
        it "is false for #{private_type}" do
          timer = Fabricate(:topic_timer, status_type: described_class.types[private_type])
          expect(timer.public_type).to be_falsey
        end
      end
    end
  end

  describe '.ensure_consistency!' do
    it 'should enqueue jobs that have been missed' do
      close_topic_timer = Fabricate(:topic_timer,
        execute_at: Time.zone.now - 1.hour,
        created_at: Time.zone.now - 2.hour
      )

      open_topic_timer = Fabricate(:topic_timer,
        status_type: described_class.types[:open],
        execute_at: Time.zone.now - 1.hour,
        created_at: Time.zone.now - 2.hour,
        topic: Fabricate(:topic, closed: true)
      )

      Fabricate(:topic_timer, execute_at: Time.zone.now + 1.hour)

      trashed_close_topic_timer = Fabricate(:topic_timer,
        execute_at: Time.zone.now - 1.hour,
        created_at: Time.zone.now - 2.hour
      )

      trashed_close_topic_timer.topic.trash!

      trashed_open_topic_timer = Fabricate(:topic_timer,
        execute_at: Time.zone.now - 1.hour,
        created_at: Time.zone.now - 2.hour,
        status_type: described_class.types[:open]
      )

      trashed_open_topic_timer.topic.trash!

      # creating topic timers already enqueues jobs
      # let's delete them to test ensure_consistency!
      Sidekiq::Worker.clear_all

      expect { described_class.ensure_consistency! }
        .to change { Jobs::ToggleTopicClosed.jobs.count }.by(4)

      expect(job_enqueued?(job: :toggle_topic_closed, args: {
        topic_timer_id: close_topic_timer.id,
        state: true
      })).to eq(true)

      expect(job_enqueued?(job: :toggle_topic_closed, args: {
        topic_timer_id: open_topic_timer.id,
        state: false
      })).to eq(true)

      expect(job_enqueued?(job: :toggle_topic_closed, args: {
        topic_timer_id: trashed_close_topic_timer.id,
        state: true
      })).to eq(true)

      expect(job_enqueued?(job: :toggle_topic_closed, args: {
        topic_timer_id: trashed_open_topic_timer.id,
        state: false
      })).to eq(true)
    end
  end
end
