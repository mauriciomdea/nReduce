class Stats

  # Returns the ids of checkins that this user has seen during the given time period
  # It will check for direct relationships (mentor -> startup), as well as user's startup -> startups
  # It will also ignore any checkins created by this user's startup
  # def self.checkin_ids_seen(from_time, to_time, checkins_by_startup = [])
  #   # Grab all completed checkins completed during this time period to see how many you did/ didn't comment on
  #   checkins_by_startup ||= Hash.by_key(Checkin.where(['created_at > ? AND created_at < ?', from_time.to_s(:db), to_time.to_s(:db)]).completed.all, :startup_id, nil, true)

  #   if self.entrepreneur? and !self.startup.blank?
  #     user_relationship_history = Relationship.history_for_entity(self.startup, 'Startup')
  #   end
  #   user_relationship_history

  #   user_relationship_history = Relationship.history_for_entity(self.startup)
  # end
  
    # Calculate engagement metrics for all users
    # Limitations:
    # - doesn't account for when team members are added, so they will get penalized if added
    # - doesn't calculate metrics for mentors or investors
    # Calculates avg number of comments given per checkin seen by each user per week
    # Writes data to rating attribute on user and startup
    # @from_time (start metrics on this date) - this is changed to be at the beginning of checkin time, because otherwise the results are skewed if in the middle of a checkin period
    # @to_time (optional - end metrics on this date, defaults to now)
  def self.calculate_engagement_metrics(from_time = nil, to_time = nil, dont_save = false, max_comments_per_checkin = 2)
    from_time ||= Time.now - 4.weeks
    from_time = Checkin.week_start_for_time(from_time)
    to_time ||= Time.now
    return 'From time is not after to time' if from_time > to_time

    # Grab all comments that everyone created during the time period
    comments_by_user = Hash.by_key(Comment.where(['created_at > ? AND created_at < ?', from_time.to_s(:db), to_time.to_s(:db)]).all, :user_id, nil, true)

    # Grab all completed checkins completed during this time period to see how many you did/ didn't comment on
    checkins_by_startup = Hash.by_key(Checkin.where(['created_at > ? AND created_at < ?', from_time.to_s(:db), to_time.to_s(:db)]).completed.all, :startup_id, nil, true)

    # Looping through all startups
    #
    results = {}
    Startup.includes(:team_members).all.each do |startup|
      num_for_startup = 0.0
      results[startup.id] = {}
      results[startup.id][:total] = nil

      # All the checkins this startup has completed by id
      checkins_by_this_startup = Hash.by_key(checkins_by_startup[startup.id], :id)

      # Need to figure out when a startup was connected to other startups so we only count checkins they saw
      # Since relationships have inverse, this will get both
      relationships = Relationship.history_for_entity(startup, 'Startup')

      # Skip if they're not connected to anyone
      next if relationships.blank? or relationships['Startup'].blank?
      # Only use startup relationships
      relationships = relationships['Startup']

      # Gather all startup ids that this startup was connected to
      startup_ids = relationships.keys

      valid_checkin_ids = []
      # How many checkins did your connected startups make?
      startup_ids.map do |startup_id|
        # iterate through checkins and see if they were connected at that time. If so add to num checkins seen
        next if checkins_by_startup[startup_id].blank?
        checkins_by_startup[startup_id].each do |c|
          # relationships is array of [approved at Time, rejected at Time (or current time if not rejected)]
          if relationships[startup_id].first <= c.completed_at && relationships[startup_id].last >= c.completed_at
            valid_checkin_ids << c.id
          end
        end
      end

      # Iterate through each team member and calculate engagement metrics
      startup.team_members.each do |user|
        rating = nil

        # Skip if their connections haven't made any checkins
        unless valid_checkin_ids.blank?
          num_comments_by_user = 0
          # What is total number of comments by this user on the checkins seen?
          # - ignore comments on your own checkins
          # - max 2 comments per checkin are counted
          unless comments_by_user[user.id].blank?
            # Key comments by checkin id so we can see how many the user made per checkin
            comments_by_checkin_id = Hash.by_key(comments_by_user[user.id], :checkin_id, nil, true)
            comments_by_checkin_id.each do |checkin_id, comments|
              # skip if they weren't connected or this was one of their checkins
              next unless valid_checkin_ids.include?(checkin_id)

              # limit count to max comments per checkin number
              num_comments_by_user += (comments.size > max_comments_per_checkin ? max_comments_per_checkin : comments.size)
            end
          end
          rating = (num_comments_by_user.to_f / valid_checkin_ids.size.to_f).round(3)
          num_for_startup += rating
        end
        # Save user's rating and add to startup's rating
        user.rating = rating
        user.save(:validate => false) unless dont_save
        results[startup.id][user.id] = rating
      end

      # calculate after for startup
      rating = nil
      rating = num_for_startup.round(3) unless valid_checkin_ids.blank?
      startup.rating = rating
      startup.save(:validate => false) unless dont_save
      results[startup.id][:total] = rating
    end
    results
  end

  def self.checkins_per_week_for_chart(since = 10.weeks)
    Checkin.group(:week).where(['created_at > ?', Time.now - since]).order(:week).count.map{|week, num| OpenStruct.new(:key => week, :value => num) }
  end

  def self.comments_per_week_for_chart(since = 10.weeks)
    c_by_w = {}
    Comment.where(['created_at > ?', Time.now - since]).each do |c| 
      week = Week.integer_for_time(c.created_at, :before_checkin)
      c_by_w[week] ||= 0
      c_by_w[week] += 1
    end
    c_by_w.sort.map{|arr| OpenStruct.new(:key => arr.first, :value => arr.last) }
  end

  def self.startups_activated_per_week_for_chart(since = 10.weeks)
    date_start = Time.now - since
    a_by_w = {}
    current = Week.integer_for_time(Time.now)
    last = Week.integer_for_time(date_start)
    while current > last
      a_by_w[current] = 0
      current = Week.previous(current)
    end
    c_by_s = Hash.by_key(Checkin.ordered.all, :startup_id, nil, true)
    c_by_s.each do |startup_id, checkins|
      # Skip unless their first checkin was after the date limit
      next unless checkins.first.time_window.first > date_start
      a_by_w[checkins.first.week] += 1
    end
    a_by_w.sort.map{|arr| OpenStruct.new(:key => arr.first, :value => arr.last) }
  end

   # Creates data for chart that displays how many active connections there are per startup, per week
   # Active connection is someone who has checked in that week
   # Returns {:categories => [201223, 201224, 201225], :series => [{'0 Connections' => [35, 45, 56]}, {'1 Connection' => [23, 26, 15]}]}
   # hash with week as key, value is number of startups
  def self.connections_per_startup_for_chart(since = 10.weeks,  max_active = 10)
    # Populate categories
    tmp_data = Stats.generate_week_hash(Time.now - since)
    calc_data = tmp_data.dup

    # Load checkins into hash keyed by startup id, and then by week
    checkins_by_startup = Stats.checkins_by_startup_and_week(tmp_data.keys.first)

    Startup.all.each do |s|
      # First get relationship and checkin history for startup
      rh = Relationship.history_for_entity(s, 'Startup')['Startup']

      next if checkins_by_startup[s.id].blank?
        
      # For each week they were active (checked in), count how many of their connections were active (checked in)
      checkins_by_startup[s.id].each do |week, checkin|
        # Now check each startup they were connected to and see if they connected and checked in that week

        active_connections_this_week = 0

        checkin_window = checkin.time_window
        unless rh.blank?
          rh.each do |startup_id, rel_window|
            # See if they were connected before checkin window closed, and that the relationship didn't end before checkin window closed
            # Should it check to see if you're connected after to give comments?
            if rel_window.first < checkin_window.last && rel_window.last > checkin_window.last
              # Now see if this startup checked in this week
              active_connections_this_week += 1 if checkins_by_startup[startup_id].present? && checkins_by_startup[startup_id][week].present?
            end
          end
          active_connections_this_week = max_active if active_connections_this_week > max_active
        end

        calc_data[week][active_connections_this_week] ||= 0
        calc_data[week][active_connections_this_week] += 1
      end
    end

    categories = tmp_data.keys
    series = {}
    max_active.downto(0).each do |num_connections|
      series[num_connections.to_s] = []
      categories.each do |week|
        series[num_connections.to_s] << (calc_data[week][num_connections].present? ? calc_data[week][num_connections] : 0)
      end
    end
    {:categories => categories, :series => series }
  end


   # Find all startups who have done a checkin, and then track their continued activity til the present
  def self.weekly_retention_for_chart(since = 10.weeks)
    # find first startup and limit weeks to start there
    first_startup_joined_at = Startup.order('created_at ASC').first.created_at
    weeks = Stats.generate_week_hash(first_startup_joined_at)
    checkins_by_startup = Stats.checkins_by_startup_and_week(weeks.keys.first)
    startups = Hash.by_key(Startup.where(:id => checkins_by_startup.keys).all, :id)

    # Group startups by date created
    weeks.keys.each do |week|
      time_window = Week.window_for_integer(week, :before_checkin)
      ids = []
      startups.values.each do |s|
        ids << s.id if time_window.first <= s.created_at && time_window.last >= s.created_at
      end

      # Now iterate through each week and see if these startups were active
      active_per_week = []
      weeks.keys.each do |week|
        num = 0
        ids.each do |startup_id|
          num += 1 if checkins_by_startup[startup_id].present? && checkins_by_startup[startup_id][week.to_i].present?
        end
        active_per_week << num
      end

      weeks[week] = active_per_week
    end
    { :categories => weeks.keys, :series => weeks }
  end

  def self.comments_per_checkin_for_chart(since = 10.weeks, max_comments = 10)
    weeks = Stats.generate_week_hash(Time.now - since).keys
    checkins = Checkin.where(['week >= ?', weeks.first]).all
    comments_per_checkin = Comment.where(:checkin_id => checkins.map{|c| c.id }).group(:checkin_id).count
    # Populate weeks hash with array for each # of comments
    data = {}
    blank_arr = []
    1.upto(weeks.size).each do |i|
      blank_arr << 0
    end
    max_comments.downto(0) do |num|
      data[num.to_s] = blank_arr.dup
    end

    # count number of comments each checkin got, grouped by week
    checkins.each do |c|
      if comments_per_checkin[c.id].present?
        num = comments_per_checkin[c.id] > max_comments ? max_comments : comments_per_checkin[c.id]
      else
        num = 0
      end
      data[num.to_s][weeks.index(c.week)] += 1
    end
    {:categories => weeks, :series => data}    
  end

  def self.checkins_by_startup_and_week(since_week = nil)
    # Load checkins into hash keyed by startup id, and then by week
    checkins_by_startup = {}
    checkins = since_week.present? ? Checkin.where(['week >= ?', since_week]).all : Checkin.all
    checkins.each do |c|
      checkins_by_startup[c.startup_id] ||= {}
      checkins_by_startup[c.startup_id][c.week] = c
    end
    checkins_by_startup
  end

  def self.generate_week_hash(since_date = nil)
    since_date ||= Time.now - 10.weeks
    tmp = []
    current = Week.integer_for_time(Time.now)
    last = Week.integer_for_time(since_date)
    while current > last
      tmp << current
      current = Week.previous(current)
    end
    # create hash
    weeks = {}
    tmp.reverse.each do |week|
      weeks[week] = {}
    end
    weeks
  end
end