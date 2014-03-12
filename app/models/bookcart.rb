class Bookcart

  attr_reader :delegates, :deleted_details, :booking_version

  def initialize(event, booking_id=nil)
    @event_id = event.id
    @delegates = []
    @booking_id = booking_id
    raise ArgumentError, "illegal booking id" if booking_id && (book = event.tbbookings.find_by_id(booking_id)).blank?
    @booking_version = @booking_id.blank? ? 0 : book.lock_version
    @bookcart_id = Tbbookcart.create().id
    @delegates = booking.load_in_cart(bookcart) if booking_id
    @index = booking_id.nil? ? 0 : @delegates.size
  end

  def event
    Tbevent.find(@event_id)
  end

  def receipt
    Tbreceipt.find(@receipt_id)
  end

  def bookcart
    Tbbookcart.find(@bookcart_id)
  end

  def add_delegate(delegate)
    raise ArgumentError, "blank id passed at Bookcart as a delegate" if delegate.id.blank?
    raise MaxDelegatesExceeded, "maximum number of delegates #{event.fddelegate_max_booking} exceeded" if active_delegates.size > event.fddelegate_max_booking
    raise ArgumentError, "invalid package for cart" if delegate.tbpackage.tbdelegate_type.tbevent_id.to_i != @event_id.to_i
    @delegates[curr_index = @index] = delegate.id
    @index += 1
    curr_index
  end

  def delegates_obj
    Tbbookcart.find(@bookcart_id).tbcart_delegates.find(:all, :order => 'fdforename, fdsurname')
  end

  def active_delegates
    delegates_obj.select { |d| !d.fdcancelled }
  end

  def delegate_idx(delegate)
    @delegates.index(delegate.id)
  end

  def get_delegate(idx)
    check_legal_idx(idx)
    bookcart.tbcart_delegates.find_by_id(@delegates[idx.to_i])
  end

  def was_loaded?
    !@booking_id.blank?
  end

  def booking
    @booking_id.blank? ? event.tbbookings.build(:fdcountry => event.tbcoordinator.fdcountry, :fdbill_country => event.tbcoordinator.fdcountry) : event.tbbookings.find(@booking_id)
  end

  def save!(arg_booking)
    Tbcoordinator.transaction do
      arg_booking.lock_version = @booking_version
      arg_booking.set_defaults(self)
      arg_booking.save!
      receipt = arg_booking.tbreceipts.build
      arg_booking.copy_bill_details_to_receipt(receipt)
      receipt.save!
      @receipt_id = receipt.id
      raise "no delegates in bookcart at save!" if delegates_obj.blank?
      delegates_obj.each { |d| d.save_in_booking!(arg_booking) }
      receipt.set_payment_details(arg_booking.payment_method.to_s)
      receipt.save!
      arg_booking.notify_booking_saved
    end
    @booking_id = arg_booking.id if @booking_id.blank?
  end

  def clear!
    delegates_obj.each do |cart_del|
      choice_ids = cart_del.tbcart_choices.collect { |c| c.id }
      choice_ids.each { |c_id| TbcartChoice.delete(c_id) }
      TbcartDelegate.delete(cart_del.id)
    end
    bookcart.destroy
    true
  end

  def total(total_type = :gross)
    delegates_to_sum = delegates_obj.delete_if { |d| !d.fdcancelled.blank? }
    return nil if delegates_to_sum.blank?
    Price.sum(delegates_to_sum.collect { |d| d.total })
  end

  def filled_forms?
    [[], [true]].member?(active_delegates.map { |d| d.filled_form? }.uniq)
  end

  def free_of_charge?
    delegates_obj.inject(true) { |truth, d| truth && d.tbpackage.fdfree_of_charge? }
  end

  private

  def check_legal_idx(idx)
    raise ArgumentError, "invalid delegate id \"#{idx}\"" unless !idx.blank? && idx.respond_to?(:to_i) && (0..100).member?(idx.to_i)
  end
end

class MaxDelegatesExceeded < ArgumentError
end
