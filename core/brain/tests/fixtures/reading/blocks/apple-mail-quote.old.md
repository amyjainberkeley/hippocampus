Inbox – 14 messages

# Re: Rounding fix for the October invoices
Priya Raman <priya@northwind.example>
To: Sam Lee <sam@northwind.example>
Oct 12, 2026 at 10:02 AM

Sam,

The fix works on the October invoices: every total now matches the processor to the cent.

I will close the ticket once the changelog is out.
Priya

> On Oct 11, 2026, at 6:40 PM, Sam Lee <sam@northwind.example> wrote:
> Here is the change for the October invoices. Totals round half to even
> once, on the whole order, instead of on each line.
>
> Can you check invoices 1042 and 1043 before I merge it?
> The test file is tax_tests.rs.
>
> Thanks,
> Sam
