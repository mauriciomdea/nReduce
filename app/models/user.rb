class User < ActiveRecord::Base
  acts_as_mappable
  belongs_to :startup
  has_many :authentications
  has_one :meeting, :class_name => 'Meeting', :through => :startup
  has_many :organized_meetings, :class_name => 'Meeting', :foreign_key => 'organizer_id'
  has_many :sent_messages, :foreign_key => 'sender_id'
  has_many :received_messages, :foreign_key => 'recipient_id'

  # Include default devise modules. Others available are:
  # :token_authenticatable, :confirmable,
  # :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable #, :confirmable #, :omniauthable

  # Setup accessible (or protected) attributes for your model
  attr_accessible :email, :password, :password_confirmation, :remember_me, :name, :skill_list, :startup, :mentor, :investor, :location, :phone

  validates_presence_of :location

  before_save :geocode_location

  acts_as_taggable_on :skills

  def mailchimp!
    return true if mailchimped?
    return false unless email.present?
    return false unless Settings.mailchimp.enabled

    h = Hominid::API.new(Settings.mailchimp.api_key)
    h.list_subscribe(Settings.apis.mailchimp.everyone_list_id, email, {}, "html", false)

    h.list_subscribe(Settings.apis.mailchimp.startup_list_id, email, {}, "html", false) if startup?
    h.list_subscribe(Settings.apis.mailchimp.mentor_list_id, email, {}, "html", false) if mentor?

    self.mailchimped = true
    self.save!

  rescue => e
    Rails.logger.error "Unable put #{email} to mailchimp"
    Rails.logger.error e
  end

  #
  # OMNIAUTH LOGIC
  #
  
  def self.auth_params_from_omniauth(omniauth)
    prms = {:provider => omniauth['provider'], :uid => omniauth['uid']}
    if omniauth['credentials']
      prms[:token] = omniauth['credentials']['token'] if omniauth['credentials']['token']
      prms[:secret] = omniauth['credentials']['secret'] if omniauth['credentials']['secret']
    end
    prms
  end

  def apply_omniauth(omniauth)
    begin
      # TWITTER
      if omniauth['provider'] == 'twitter'
        logger.info omniauth['info'].inspect
        self.name = omniauth['info']['name'] if name.blank? and !omniauth['info']['name'].blank?
        self.external_pic_url = omniauth['info']['image'] unless omniauth['info']['image'].blank?
        self.location = omniauth['info']['location'] if !omniauth['info']['location'].blank?
        self.twitter = omniauth['info']['nickname']
      elsif omniauth['provider'] == 'linkedin'
        self.name = omniauth['info']['name'] if name.blank? and !omniauth['info']['name'].blank?
        self.external_pic_url = omniauth['info']['image'] unless omniauth['info']['image'].blank?
        self.linkedin_url = omniauth['info']['urls']['public_profile'] unless omniauth['info']['urls'].blank? or omniauth['info']['urls']['public_profile'].blank?
      # FACEBOOK
      elsif omniauth['provider'] == 'facebook'
        self.name = omniauth['user_info']['name'] if name.blank? and !omniauth['user_info']['name'].blank?
        if self.email.blank?
          self.email = omniauth['extra']['user_hash']['email'] if omniauth['extra'] && omniauth['extra']['user_hash'] && !omniauth['extra']['user_hash']['email'].blank?
          self.email = omniauth['user_info']['email'] unless omniauth['user_info']['email'].blank?
        end
        self.email = 'null@null.com' if self.email.blank?
        if omniauth['extra']['user_hash']['location'] and !omniauth['extra']['user_hash']['location']['name'].blank?
          self.location = omniauth['extra']['user_hash']['location']['name']
        end
      end
    rescue
      logger.warn "ERROR applying omniauth with data: #{omniauth}"
    end
    authentications.build(User.auth_params_from_omniauth(omniauth))
  end

  def password_required?
    (authentications.empty? || !password.blank?) #&& super
  end
  
  def uses_password_authentication?
    !self.encrypted_password.blank?
  end
  
   # Returns boolean if user is authenticated with a provider 
   # Parameter: provider_name (string)
  def authenticated_for?(provider_name)
    authentications.where(:provider => provider_name).count > 0
  end

  def internal_email
    "#{twitter || self.id}@users.nreduce.com"
  end

  def hipchat_name
    n = !self.name.blank? ? self.name : self.twitter.sub('@', '')
    s = self.matching_startup
    if !s.blank?
      n += " | #{s.name}"
    else
      # Name needs to have first and last name or else hipchat considers it invalid
      n += ' S12' if(n.split(/\s+/).size < 2)
    end
    n
  end

  def hipchat?
    hipchat_username.present?
  end

  def generate_hipchat!
    return if hipchat?

    pass = NReduce::Util.friendly_token.to_s[0..8]
    prms = {:auth_token => Settings.hipchat.token,
            :email => internal_email,
            :name => hipchat_name, 
            :title => 'nReducer', 
            :is_group_admin => 0,
            :password => pass, 
            :timezone => 'UTC'}

    # Have to post manually to API because for some reason gem doesn't pass auth token properly
    uri = URI.parse("https://api.hipchat.com/v1/users/create")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Post.new(uri.request_uri)
    request.set_form_data(prms)
    response = http.request(request)
    if response.code == '200'
      self.hipchat_username = internal_email
      self.hipchat_password = pass
      self.save!
    else
      false
    end
    # hipchat = HipChat::API.new(Settings.hipchat.token)
    # pass = NReduce::Util.friendly_token.to_s[0..8]
    # if hipchat.users_create(internal_email, name, 'nReducer', 0, pass)
    #   self.hipchat_username = internal_email
    #   self.hipchat_password = pass
    #   self.save!
    # else
    #   false
    # end
  end

  protected

  def geocode_location
    return true if self.location.blank? or (!self.location_changed? and !self.lat.blank?)
    begin
      res = User.geocode(self.location)
      self.lat, self.lng = res.lat, res.lng
    rescue
      self.errors.add(:location, "could not be geocoded")
    end
  end
end