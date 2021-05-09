module FilterHelper
  def is_filter_active?
    params[:from] || params[:to] || params[:sort] || params[:expired] || params[:map] || params[:hero] || params[:category] || params[:author] || params[:players]
  end
end
