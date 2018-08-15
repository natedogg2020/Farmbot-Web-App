# Farmbot Device models all data related to an actual FarmBot in the real world.
class Device < ApplicationRecord
  DEFAULT_MAX_LOGS    = 100
  DEFAULT_MAX_IMAGES  = 100
  DEFAULT_MAX_CONFIGS = 100

  TIMEZONES           = TZInfo::Timezone.all_identifiers
  BAD_TZ              = "%{value} is not a valid timezone"
  THROTTLE_ON         = "Device is sending too many logs (%s). " \
                        "Suspending log storage and display until %s."
  THROTTLE_OFF        = "Cooldown period has ended. "\
                        "Resuming log storage."
  CACHE_KEY           = "devices.%s"

  has_many  :farmware_envs,         dependent: :destroy
  has_many  :farm_events,            dependent: :destroy
  has_many  :farmware_installations, dependent: :destroy
  has_many  :images,                 dependent: :destroy
  has_many  :logs,                   dependent: :destroy
  has_many  :peripherals,            dependent: :destroy
  has_many  :pin_bindings,           dependent: :destroy
  has_many  :plant_templates,        dependent: :destroy
  has_many  :points,                 dependent: :destroy
  has_many  :regimens,               dependent: :destroy
  has_many  :saved_gardens,          dependent: :destroy
  has_many  :sensor_readings,        dependent: :destroy
  has_many  :sensors,                dependent: :destroy
  has_many  :sequences,              dependent: :destroy
  has_many  :token_issuances,        dependent: :destroy
  has_many  :tools,                  dependent: :destroy
  has_many  :webcam_feeds,           dependent: :destroy
  has_many  :diagnostic_dumps,       dependent: :destroy
  has_one   :fbos_config,            dependent: :destroy
  has_many  :in_use_tools
  has_many  :in_use_points
  has_many  :users

  validates_presence_of :name
  validates :timezone,
    inclusion: { in: TIMEZONES, message: BAD_TZ, allow_nil: true }
  [FbosConfig, FirmwareConfig, WebAppConfig].map do |klass|
    name = klass.table_name.singularize.to_sym
    has_one name, dependent: :destroy
    define_method(name) { super() || klass.create!(device: self) }
  end

  # Give the user back the amount of logs they are allowed to view.
  def limited_log_list
    Log
      .order(created_at: :desc)
      .where(device_id: self.id)
      .limit(max_log_count || DEFAULT_MAX_LOGS)
  end

  def self.current
    RequestStore.store[:device]
  end

  def self.current=(dev)
    RequestStore.store[:device] = dev
  end

  # Sets Device.current to `self` and returns it to the previous value when
  #  finished running block. Usually this is unecessary, but may be required in
  # background jobs. If you are not receiving auto_sync data on your client,
  # you probably need to use this method.
  def auto_sync_transaction
    prev           = Device.current
    Device.current = self
    yield
    Device.current = prev
  end

  def tz_offset_hrs
    Time.now.in_time_zone(self.timezone || "UTC").utc_offset / 1.hour
  end

  def plants
    points.where(pointer_type: "Plant")
  end

  TIMEOUT = 150.seconds

  # Like Device.find, but with 150 seconds of caching to avoid DB calls.
  def self.cached_find(id)
    Rails
      .cache
      .fetch(CACHE_KEY % id, expires_in: TIMEOUT) { Device.find(id) }
  end

  def refresh_cache
    # Why? Device.new(self.as_json)???
    #
    # "Some objects cannot be dumped: if the objects to be dumped include
    # bindings, procedure or method objects, instances of class IO, or singleton
    # objects, a TypeError will be raised."
    # https://ruby-doc.org/core-2.3.1/Marshal.html
    # TODO: Someone plz send help! - RC
    Rails.cache.write(CACHE_KEY % self.id, Device.new(self.as_json))
  end

  # Sets the `throttled_at` field, but only if it is unpopulated.
  # Performs no-op if `throttled_at` was already set.
  def maybe_throttle(violation)
    # Some log validation errors will result in until_time being `nil`.
    if (violation && throttled_until.nil?)
      et = violation.ends_at
      reload.update_attributes!(throttled_until: et,
                                throttled_at:    Time.now)
      refresh_cache
      cooldown = et.in_time_zone(self.timezone || "UTC").strftime("%I:%M%p")
      info = [violation.explanation, cooldown]
      cooldown_notice(THROTTLE_ON % info, et, "warn")
    end
  end

  def maybe_unthrottle
    if throttled_until.present?
      old_time = throttled_until
      reload # <= WHY!?! TODO: Find out why it crashes without this.
        .update_attributes!(throttled_until: nil, throttled_at: nil)
      refresh_cache
      cooldown_notice(THROTTLE_OFF, old_time, "info")
    end
  end
  # Send a realtime message to a logged in user.
  def tell(message, channels = [], type = "info")
    log  = Log.new({ device:        self,
                     message:       message,
                     created_at:    Time.now,
                     channels:      channels,
                     major_version: 99,
                     minor_version: 99,
                     meta:          {},
                     type:          type })
    json = LogSerializer.new(log).as_json.to_json

    Transport.current.amqp_send(json, self.id, "logs")
    return log
  end

  def cooldown_notice(message, throttle_time, type, now = Time.current)
    hours    = ((throttle_time - now) / 1.hour).round
    channels = [(hours > 2) ? "email" : "toast"]
    tell(message, channels , type).save
  end

  def regimina
    regimens # :(
  end

  # CONTEXT:
  #  * We tried to use Rails low level caching, but it hit marshalling issues.
  #  * We did a hack with Device.new(self.as_json) to get around it.
  #  * Mutations does not allow unsaved models
  #  * We converted the `model :device, class: Device` to:
  #     `duck :device, methods [:id, :is_device]`
  #
  # This methd is not required, but adds a layer of safety.
  def is_device # SEE: Hack in Log::Create. TODO: Fix low level caching bug.
    true
  end
end
