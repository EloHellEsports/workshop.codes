class Block < ApplicationRecord
  belongs_to :user

  has_many_attached :images, dependent: :destroy

  enum content_type: { profile: 0, post: 1 }

  serialize :properties

  validates :name, presence: true
  validates :content_type, presence: true
  validates :user_id, presence: true
  validates :images, content_type: ["image/png", "image/jpg", "image/jpeg"],
                     size: { less_than: 2.megabytes }
end
