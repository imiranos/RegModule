class SuperBookingController < ApplicationController

  helper :prices, :online_payments
  rescue_from Consumable::QuantityLessThanZero, :with => :no_enough_available
  include ActiveMerchant::Billing::Integrations
  include PayableController
  filter_parameter_logging :cc_number, :cc_cvv2

  def new
    session[:bookcart].clear! if session[:bookcart].is_a?(Bookcart)
    session[:booking_id] = nil
    session[:bookcart] = Bookcart.new(@event)
    [:notice, :warn].each { |severity| flash[severity] = flash[severity] }
    redirect_to new_delegate_resource
  end

  def edit
    @booking.set_defaults(session[:bookcart])
    if session[:bookcart].was_loaded?
      @booking.fdemail_confirmation = @booking.fdemail
    end
  end

  def show
    @delegates = @booking.tbdelegates.delete_if { |d| d.fdcancelled }
    @receipt = @booking.current_payment_receipt
  end

  def update
    @booking.attributes = params[:booking]
    @booking.set_defaults(session[:bookcart])
    unless @booking.valid?
      render :action => :edit
      return false
    end
    @track_transaction = @booking.new_record?
    session[:bookcart].save!(@booking)
    @receipt = session[:bookcart].receipt
    @notification_type = @booking.notification_type
    reload_booking
    #Breakpoint.breakpoint(nil, binding)
    render :action => :show
    session[:bookcart].clear!
    session[:bookcart] = nil
    session[:booking_id] = @booking.id
  end

  def pay
    @delegates = @booking.tbdelegates
    @receipt = @booking.current_payment_receipt
    super
  end

  def datacash_3ds_callback
    @receipt = @booking.current_payment_receipt
    super
  end

  def after_payment
    @delegates = @booking.tbdelegates
    @receipt = @booking.current_payment_receipt
    @notification_type = @receipt.payment_notification_type
  end

  def after_paypal
    after_payment
  end

  private

  def scope_delegates
    @delegates = session[:bookcart].delegates_obj
  end

  def reload_booking
    @booking = session[:bookcart].booking
  end

  def check_filled_forms
    return true if session[:bookcart].filled_forms?
    flash[:warn] = "some delegates need to complete their data"
    redirect_to delegate_list_resource
  end

  def no_enough_available
    flash[:warn] = "Sorry, there were not enough available resources to complete your booking. Please try again either by changing the package type or booking fewer people"
    redirect_to delegate_list_resource
  end

  def self.super_filters
    before_filter :scope_event, :redirect_on_exit_without_saving
    before_filter :scope_booking, :except => [:new, :read]
    before_filter :check_filled_forms, :except => [:new, :read, :show, :pay, :datacash_3ds_callback, :after_payment, :after_paypal]
    before_filter :scope_delegates, :only => [:update]
    before_filter :set_audit_user, :redirect_on_cancel_booking, :only => [:update]
  end

  def redirect_on_exit_without_saving
    if params[:commit] == 'Exit without saving'
      flash[:notice] = "Your changes were not saved, you can start a new booking or leave the system by closing this page"
      redirect_to new_booking_resource
    end
  end

  def set_audit_user
    Tbbookaudit.audit_user = @realm == 'coordinator' ? @user.username(@coordinator.fdprefix) : 'delegate'
  end

  def redirect_on_cancel
  end

  def redirect_on_cancel_booking
    redirect_to delegate_list_resource if params[:commit] == 'Review delegates'
  end

end
