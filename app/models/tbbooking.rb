class Tbbooking < ActiveRecord::Base

  BILL_DETAILS = [:fdbill_contact, :fdbill_tel, :fdbill_country, :fdbill_email, :fdbill_fax, :fdbill_postcode, :fdbill_organisation, :fdbill_job_title]
  BILL_DETAILS << (1..5).map { |n| "fdbill_address_line_#{n}".to_sym }
  BILL_DETAILS.flatten!

  has_many :tbdelegates
  has_many :tbemails
  has_many :tbreceipts
  has_many :tbbookaudits, :order => 'id DESC'
  auto_compile_accessible :drop_foreign_keys, :enable => [:contactcopy, :termsaccept, :fdemail_confirmation, :payment_method]

  attr_accessor :contactcopy, :send_notification, :payment_method

  belongs_to :tbevent

  def self.find_by_refnumber(ref)
    return nil if !ref.is_a?(String) || !(ref.length > 3)
    coord_prefix = ref[0..2]
    ref_id = ref.sub(coord_prefix, '')
    return nil unless ref_id =~ /^\d+$/
    booking = self.find_by_id(ref_id)
    return nil if booking.blank? || booking.tbevent.tbcoordinator.fdprefix != coord_prefix
    booking
  end

  def contactcopy=(value)
    if value.respond_to? 'to_i'
      @contactcopy = value.to_i == 1 ? true : false
    else
      @contactcopy = value == true ? true : false
    end
  end

  def payment_method
    @payment_method ||= tbevent.payment_methods.first
  end

  def receipt_payment_method
    first_receipt.payment_method
  end

  def fullname
    [fdtitle, fdforename, fdsurname].join(' ')
  end

  def first_receipt
    tbreceipts.find(:first, :order => "id")
  end

  def current_receipt
    tbreceipts.find(:first, :order => "id DESC")
  end

  def current_payment_receipt
    last_payment_receipt = tbreceipts.find(:first, :order => "id DESC", :conditions => ['fdtype <> ?', 'NullPayment'])
    (last_payment_receipt && last_payment_receipt.pending_online?) ? last_payment_receipt : current_receipt
  end

  def pending_online?
    current_payment_receipt.pending_online?
  end

  def copy_bill_details_to_receipt(receipt)
    BILL_DETAILS.each { |d| receipt.send("#{d}=", self.send(d)) }
  end

  def tbcoordinator
    tbevent.tbcoordinator
  end

  def refnumber(prefix = nil)
    prefix ||= tbcoordinator.fdprefix
    "#{prefix + id.to_s}"
  end

  def delegate_types
    self.tbdelegates.select { |d| d.fdcancelled.blank? }.map { |d| d.tbdelegate_type }.uniq
  end

  def packages
    self.tbdelegates.select { |d| d.fdcancelled.blank? }.map { |d| d.tbpackage }.uniq
  end

  validates_ar_descriptions do
    describe :fdemail, :fdbill_email, :as => :email
  end

  def load_in_cart(bookcart)
    raise "load in cart called for booking #{self.id} with nil bookcart" if bookcart.blank?
    self.tbdelegates.collect { |t| t.to_cart_delegate!(bookcart).id }
  end

  def self.authenticate(username_with_prefix, password)
    if username_with_prefix =~ /^[[:alnum:]]{4,}$/
      prefix, uname = username_with_prefix.slice!(0..2), username_with_prefix
      coordinator = Tbcoordinator.find_by_fdprefix(prefix.upcase)
      if coordinator.blank?
        raise "Username or password invalid"
      else
        user = coordinator.tbbookings.find(:first, :conditions => ["tbbookings.id = ?", uname])
        if user.blank? || user.fdpassword != password
          raise "Username or password invalid"
        else
          user
        end
      end
    else
      raise "Username or password invalid"
    end
  end

  def cancelled?
    delegates_cancelled = self.tbdelegates.map { |d| d.fdcancelled }
    delegates_cancelled.size == delegates_cancelled.compact.size
  end

  def update_billing_attributes(params)
    params.keys.select { |k| k=~ /^fdbill/ }.each do |billing_param|
      send("#{billing_param}=", params[billing_param])
    end
    self.class.transaction do
      save && copy_bill_details_to_receipt(current_receipt)
    end
  end

  def editable?(realm)
    true
  end

  validates_acceptance_of :termsaccept

  validates_confirmation_of :fdemail

  before_validation :cp_billing_contact, :clean_strings

  before_validation_on_create :gen_password

  def notification_type(destination='delegate', base_version=0)
    return nil if new_record?
    @notification_type = 'new_booking'
    @notification_type = self.cancelled? ? 'cancelled_booking' : 'amended_booking' if self.lock_version > base_version
    if destination == 'delegate'
      @notification_type = "before_#{current_payment_receipt.fdpayment_provider}_booking" if current_payment_receipt.pending_online?
    end
    @notification_type
  end

  def notify_booking_saved(reminder = false)
    sub_list = reminder ? %w(delegate) : %w(coordinator delegate)
    sub_list.each { |subj| self.tbemails.create(:fdtype => "#{subj}_#{notification_type(subj)}") if Tbemail::TYPES["#{subj}_#{notification_type(subj)}"] }
  end

  def notify_online_payment(receipt)
    if tbreceipts.find(:all, :conditions => "fdtype = 'OnlinePayment' AND fdpayment_received IS NULL").blank?
      self.tbemails.create(:fdtype => "delegate_#{receipt.fdpayment_provider}_received")
    end
  end

  def total(total_type = :full)
    delegates_to_sum = tbdelegates.delete_if { |d| !d.fdcancelled.blank? }
    return nil if delegates_to_sum.blank?
    sum_method = total_type == :partial ? :partial_sum : :sum
    Price.send(sum_method, (delegates_to_sum.collect { |d| d.total }))
  end

  def address
    (1..5).map { |n| send("fdaddress_line_#{n}") }.delete_if { |l| l.blank? }.join("\n")
  end

  def delegates_list
    out_rows = []
    tbdelegates.each do |delegate|
      out_rows << delegate.print_for_mail
      1.times { out_rows << nil }
    end
    out_rows.join("\n")
  end

  def delegate_booking_itinerary
    out_rows = []
    tbdelegates.each do |delegate|
      out_rows << delegate.itinerary_for_mail
      1.times { out_rows << nil }
    end
    out_rows.join("\n")
  end

  def set_defaults(cart)
    if new_record?
      set_free_of_charge_billing_contact if cart.free_of_charge?
      cp_delegate_contact(cart)
    end
  end

  private

  def set_free_of_charge_billing_contact
    %w(fdbill_contact fdbill_organisation fdbill_address_line_1 fdbill_address_line_2
    fdbill_address_line_3 fdbill_address_line_4 fdbill_address_line_5 fdbill_postcode
    fdbill_country fdbill_tel fdbill_fax).each do |billing_field|
      self.send("#{billing_field}=", 'XXX')
    end
    self.fdbill_email = self.fdemail
  end

  def cp_delegate_contact(cart)
    if cart.delegates_obj.size == 1
      del = cart.delegates_obj.first
      %w(fdtitle fdforename fdsurname fdemail fdtel).each do |field|
        send("#{field}=", del.send(field)) if send(field).blank?
      end
    end
  end

  def cp_billing_contact
    if self.contactcopy
      self.fdbill_contact = self.fullname
      self.fdbill_organisation = self.fdorganisation
      self.fdbill_job_title = self.fdjob_title
      self.fdbill_address_line_1 = self.fdaddress_line_1
      self.fdbill_address_line_2 = self.fdaddress_line_2
      self.fdbill_address_line_3 = self.fdaddress_line_3
      self.fdbill_address_line_4 = self.fdaddress_line_4
      self.fdbill_address_line_5 = self.fdaddress_line_5
      self.fdbill_postcode = self.fdpostcode
      self.fdbill_country = self.fdcountry
      self.fdbill_tel = self.fdtel
      self.fdbill_fax = self.fdfax
      self.fdbill_email = self.fdemail
    end
  end

  def gen_password
    self.fdpassword = ''
    8.times { self.fdpassword << (i = Kernel.rand(62); i += ((i < 10) ? 48 : ((i < 36) ? 55 : 61 ))).chr }
  end

end
