class PostsController < ApplicationController
  require "httparty"

  include EmailNotificationsHelper

  before_action :set_post, only: [:edit, :update, :destroy]
  before_action :set_post_images, only: [:edit]
  skip_before_action :track_ahoy_visit

  before_action only: [:edit, :update, :destroy] do
    if @post.present?
      redirect_to login_path unless current_user && current_user == @post.user
    else
      redirect_to root_path
    end
  end

  before_action :set_order, only: [:category, :hero, :map]

  before_action only: [:create, :new] do
    redirect_to login_path(elohell: params[:elohell]) unless current_user
  end

  after_action :track_action, only: [:show]

  def index
    @hot_posts = Post.includes(:user, :revisions).where(private: 0).where("hotness > 0").order("hotness DESC").limit(3)
    @posts = Post.includes(:user, :revisions).where(private: 0).order(created_at: :desc).page params[:page]
  end

  def filter
    @posts = params[:search] ? Post.includes(:user, :revisions).search(params[:search]).records.where(private: 0) : Post.where(private: 0)

    @posts = @posts.where("created_at >= ?", params[:from]) if params[:from]
    @posts = @posts.where("created_at <= ?", params[:to]) if params[:to]
    @posts = @posts.where("updated_at > ?", 6.months.ago) if params[:expired]

    @posts = @posts.order("#{ sort_switch } DESC") if params[:sort] && params[:sort] != "relevancy"

    @posts = @posts.select { |post| to_slug(post.categories).include?(to_slug(params[:category])) } if params[:category]
    @posts = @posts.select { |post| to_slug(post.maps).include?(to_slug(params[:map])) } if params[:map]
    @posts = @posts.select { |post| to_slug(post.heroes).include?(to_slug(params[:hero])) } if params[:hero]

    @posts = Kaminari.paginate_array(@posts).page(params[:page])

    track_action("Search", { search: params[:search] }) if params[:search]
  end

  def on_fire
    @posts = Post.includes(:user, :revisions).where(private: 0).where("hotness > 1").order("hotness DESC").page params[:page]
  end

  def show
    @post = Post.includes(:user, :revisions, :comments).find_by("upper(code) = ?", params[:code].upcase)

    not_found and return if @post && @post.private? && @post.user != current_user

    respond_to do |format|
      format.html {
        unless @post.present?
          revision = Revision.find_by("upper(code) = ?", params[:code].upcase)
          @post = revision.post if revision

          redirect_to post_path(revision.post.code) if revision
        end

        not_found and return unless @post.present?

        set_post_images
        @is_expired = @post.revisions.where("created_at > ?", 6.months.ago).none?
      }
      format.json {
        set_request_headers
        render json: @post, except: [:id, :user_id, :image_order, :favorites_count, :impressions_count, :hotness]
      }
    end
  end

  def redirect_nice_url
    @post = Post.find_by_nice_url!(params[:nice_url].downcase)

    track_action("Redirect Post Nice URL")

    redirect_to post_path(@post.code)
  end

  def new
    @post = Post.new

    set_elohell_data if params[:elohell].present?
  end

  def edit
  end

  def parse_markdown
    parsed_markdown = markdown(post_params[:description] || post_params[:content])

    render json: parsed_markdown, layout: false
  end

  def get_snippet
    @snippet = Post.where(private: 0).find(params[:id]).snippet

    render layout: false
  end

  def create
    @post = Post.new(post_params)
    @post.user_id = current_user.id

    if @post.save
      @revision = Revision.new(post_id: @post.id, code: @post.code, version: @post.version, snippet: @post.snippet).save

      create_activity(:create_post, post_activity_params)
      create_email_notification(:will_expire, @post.id, post_params[:email]) if email_notification_enabled
      create_collection if post_params[:new_collection] != ""

      notify_discord("New")

      redirect_to post_path(@post.code)
    else
      render :new
    end
  end

  def update
    params[:post][:nice_url] = "" if post_params[:include_nice_url] == "0"
    params[:post][:email] = "" if post_params[:email_notification] == "0"

    current_version = @post.version
    current_code = @post.code

    if @post.update(post_params)
      create_activity(:update_post, post_activity_params)
      create_collection if post_params[:new_collection] != ""

      update_email_notifications

      if (post_params[:revision].present? && post_params[:revision] != "0") || (current_code != post_params[:code]) || (current_version != post_params[:version])
        invisible = (post_params[:revision].present? && post_params[:revision] == "0") ? 0 : 1
        @revision = Revision.new(post_id: @post.id, code: @post.code, version: @post.version, description: post_params[:revision_description], snippet: @post.snippet, visible: invisible).save
      end

      notify_discord("Update")
      redirect_to post_path(@post.code)
    else
      @post.code = current_code
      render :edit
    end
  end

  def destroy
    @post.destroy
    create_activity(:destroy_post, post_activity_params)

    redirect_to posts_url
  end

  def copy_code
    @post = Post.find_by_code(post_params[:code])
    @post = Revision.find_by_code(post_params[:code]).post unless @post.present?

    track_action("Copy Code")
  end

  private

  def set_post
    @post = Post.find_by_code(params[:code])
  end

  def set_post_images
    return unless @post.present? && @post.images.any?

    @image_ids = @post.image_order || "[]"
    @ordered_images = JSON.parse(@image_ids).collect { |i| @post.images.find_by_blob_id(i) }
  end

  def create_collection
    nice_url = SecureRandom.alphanumeric(6).downcase
    @collection = Collection.create(user_id: current_user.id, title: post_params[:new_collection], nice_url: nice_url)

    @post.update(collection_id: @collection.id)
  end

  def set_order
    @order = params[:sort] ? "hotness DESC" : "updated_at DESC"
  end

  def not_found
    raise ActionController::RoutingError.new("Not Found")
  end

  def track_action(event = "Posts Visit", parameters = request.path_parameters)
    parameters["id"] = @post.id if @post.present?

    TrackingJob.perform_async(ahoy, event, parameters)
  end

  def sort_switch
    case params[:sort]
    when "views"
      "impressions_count"
    when "favorites"
      "favorites_count"
    when "created"
      "created_at"
    when "updated"
      "updated_at"
    when "on-fire"
      "hotness"
    else
      "created_at"
    end
  end

  def post_activity_params
    { ip_address: last_4_digits_of_request_ip, id: @post.id }
  end

  def post_params
    params.require(:post).permit(
      :code, :title, :include_nice_url, :nice_url, :private, :description, :version, { categories: [] }, :tags, { heroes: [] }, { maps: [] }, :snippet,
      :collection_id, :new_collection,
      :revision, :revision_description,
      :email_notification, :email,
      :image_order, images: [])
  end

  def email_notification_enabled
    post_params[:email_notification].present? && post_params[:email_notification] != "0" && post_params[:email].present?
  end

  def update_email_notifications
    if @post.email_notifications.any? && email_notification_enabled
      @post.email_notifications.last.update(email: post_params[:email])
    elsif @post.email_notifications.any? && !email_notification_enabled
      @post.email_notifications.destroy_all
    elsif email_notification_enabled
      create_email_notification(:will_expire, @post.id, post_params[:email])
    end
  end

  def set_elohell_data
    url = "https://workshop.elohell.gg/#{ params[:elohell] }/.json"
    response = HTTParty.get(url, timeout: 5, verify: false)

    if response
      @post.code = response.parsed_response["code"]
      @post.title = response.parsed_response["title"]
      @post.description = response.parsed_response["description"]
      @post.snippet = response.parsed_response["snippet"]
      @post.version = response.parsed_response["version"]
      @post.tags = response.parsed_response["tags"]
    end
  end

  def set_request_headers
    headers["Access-Control-Allow-Origin"] = "*"
  end

  def notify_discord(type)
    return unless ENV["DISCORD_NOTIFICATIONS_WEBHOOK_URL"].present?
    return if @post.private?

    set_post_images

    post = @post
    revision = @revision
    path = post_url(post.code.upcase)
    user_path = user_url(post.user.username)
    image = @ordered_images.present? ? url_for(@ordered_images.first.variant(quality: 95).processed) : ""
    avatar = @post.user.profile_image.variant(quality: 95, resize_to_fill: [120, 120]).processed

    embed = Discord::Embed.new do
      color "#3fbf74"
      thumbnail url: image
      author name: post.user.username, avatar_url: avatar, url: user_path
      title "(#{ type }) #{ post.title }"
      url path
      description post.description.truncate(500)
      add_field name: "\u200B", value: "\u200B"
      add_field name: "Code", value: post.code.upcase
      add_field name: "\u200B", value: "\u200B" if revision && post.revisions.last.description.present?
      add_field name: "Update notes", value: post.revisions.last.description.truncate(500) if revision && post.revisions.last.description.present?
      footer text: "Elo Hell Esports", icon_url: "https://elohell.gg/media/img/logos/Elo-Hell-Logo_I-C-Dark.png"
    end

    Discord::Notifier.message(embed)
  end
end
